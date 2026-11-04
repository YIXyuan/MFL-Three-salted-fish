# -*- coding: utf-8 -*-
"""
INT8 量化与交付物导出: python quantize_export.py [--model output/models/best_model.pt]

产出(output/quant_export/):
  model_fp32_fused.onnx   BN 融合后 FP32 基准(GPU 侧精度参考)
  model_int8.onnx         QDQ 静态量化 INT8 全模型(ARM 可直接用 onnxruntime 部署)
  head_fp32.onnx / head_int8.onnx   ARM 侧分类头(GAP+FC)单独交付
  weights_int8/           每层卷积 INT8 权重 npy + int32 偏置(FPGA 片上初始化用)
  quant_params.json       每层 scale/zero_point(FPGA 定点推理的核心参数, 机器可读)
  quant_params_table.md   同上内容的表格版(FPGA/ARM 组阅读用)
  preprocess_spec.json    预处理规格(必须与 FPGA 前端严格一致)
  fpga_architecture_spec.json  v1.2 结构规范(含 PG2K100 片上 RAM 预算表)
  quantization_report.json     FP32 vs INT8 一致性/精度对比
"""

import argparse
import json
import shutil
import tempfile
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

import config as C
import model as M
from dataset import iter_image_files, load_image

INPUT_NAME = "input"


def quantize_static_ascii(model_input, model_output, **kwargs):
    """onnxruntime 的形状推断(infer_shapes_path, C++ 实现)在 Windows 非 ASCII 路径下
    会静默失败(不写 -inferred.onnx 也不报错), 因此量化统一在 ASCII 临时目录执行后拷回."""
    from onnxruntime.quantization import quantize_static
    with tempfile.TemporaryDirectory(prefix="mfl_quant_") as td:
        src = Path(td) / "model.onnx"
        dst = Path(td) / "model_int8.onnx"
        shutil.copyfile(model_input, src)
        quantize_static(model_input=str(src), model_output=str(dst), **kwargs)
        shutil.copyfile(dst, model_output)


def install_streaming_calibration_patch():
    """修 OOM: ORT 的 HistogramCalibrater.collect_data (Entropy/Percentile/Distribution 共用)
    把所有样本的全部中间张量(本模型约 125MB/样本)堆在 intermediate_outputs 列表里,
    全部喂完才一次性做直方图 —— 1024 样本约 128GB, 必然 OOM(MinMax 有自己的流式实现不受影响).
    直方图 collect 支持增量合并, 故改为逐样本流式收集: 数学结果与一次性收集完全等价
    (直方图按相同规则逐次 merge), 内存上界 = 单次 ORT 运行输出(~130MB) + 直方图(数 MB)."""
    import copy as _copy
    from onnxruntime.quantization import calibrate as _cal

    def collect_data_streaming(self, data_reader):
        input_names_set = {node_arg.name for node_arg in self.infer_session.get_inputs()}
        output_names = [node_arg.name for node_arg in self.infer_session.get_outputs()]
        if not self.collector:
            self.collector = _cal.HistogramCollector(
                method=self.method, symmetric=self.symmetric, num_bins=self.num_bins,
                num_quantized_bins=self.num_quantized_bins, percentile=self.percentile,
                scenario=self.scenario)
        n = 0
        while True:
            inputs = data_reader.get_next()
            if not inputs:
                break
            outputs = self.infer_session.run(None, inputs)
            # 与上游一致: 名字同时是图输入的输出做浅拷贝(ORT#21922 变通); 即收即用不累积
            fixed = [_copy.copy(o) if output_names[i] in input_names_set else o
                     for i, o in enumerate(outputs)]
            slim = {k: v for k, v in zip(output_names, fixed, strict=False)
                    if k in self.tensors_to_calibrate}
            self.collector.collect(slim)
            n += 1
        if n == 0:
            raise ValueError("No data is collected.")
        self.clear_collected_data()

    # HistogramCollector.collect 每次调用都打印一行固定文案, 逐样本收集会有上千行噪音, 静默之
    _orig_collect = _cal.HistogramCollector.collect

    def quiet_collect(self, name_to_arr):
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            return _orig_collect(self, name_to_arr)

    _cal.HistogramCalibrater.collect_data = collect_data_streaming
    _cal.HistogramCollector.collect = quiet_collect
    print("[patch] 校准已切换为流式收集(修 Percentile/Entropy 大样本 OOM)")


# ---------------------------------------------------------------------------
# 校准数据
# ---------------------------------------------------------------------------
def calib_paths(n):
    """校准图池(均匀抽样, 顺序固定可复现).
    CALIB_POOL="train": 全部取 train 缓存; "train+val": 掺 50% val(阶梯 C)."""
    train_files = [str(p) for p in iter_image_files(C.TRAIN_IMAGE_DIR)]
    if not train_files:
        raise RuntimeError("训练图目录为空, 无法校准")
    if str(getattr(C, "CALIB_POOL", "train")).lower() == "train+val":
        val_dir = C.cache_split_dir("val")
        val_files = [str(p) for p in iter_image_files(val_dir)] if val_dir.exists() else []
        if val_files:
            half = min(n // 2, len(val_files))
            n = min(n, len(train_files) + half)
            t_pick = np.linspace(0, len(train_files) - 1, n - half).round().astype(int)
            v_pick = np.linspace(0, len(val_files) - 1, half).round().astype(int)
            pool = [train_files[i] for i in t_pick] + [val_files[i] for i in v_pick]
            np.random.RandomState(C.SEED).shuffle(pool)     # 混匀, 避免按来源分段
            return pool
        print("[提示] CALIB_POOL=train+val 但 val 缓存缺失, 退回纯 train 池")
    n = min(n, len(train_files))
    pick = np.linspace(0, len(train_files) - 1, n).round().astype(int)   # 均匀抽样
    return [train_files[i] for i in pick]


def verify_paths(n, exclude=None):
    """T1 修复: 独立验证样本——优先 val 缓存(与校准 train 池严格分离);
    val 缓存缺失时退化为 train 池并剔除校准用过的图(非独立域, 仅保底可用).
    返回 (paths, 来源说明)."""
    val_dir = C.cache_split_dir("val")
    if val_dir.exists():
        files = [str(p) for p in iter_image_files(val_dir)]
        if len(files) >= 32:
            n = min(n, len(files))
            pick = np.linspace(0, len(files) - 1, n).round().astype(int)
            return [files[i] for i in pick], "val-cache"
    files = [str(p) for p in iter_image_files(C.TRAIN_IMAGE_DIR)]
    if exclude:
        excl = set(exclude)
        filtered = [f for f in files if f not in excl]
        if filtered:
            files = filtered
    n = min(n, len(files))
    pick = np.linspace(0, len(files) - 1, n).round().astype(int)
    return [files[i] for i in pick], "train-pool-excluding-calib(非独立域, 保底口径)"


class CalibReader:
    """全模型校准: 惰性读取图像(不增强, 与推理预处理完全一致)"""

    def __init__(self, paths):
        self.paths = paths
        self.idx = 0

    def get_next(self):
        if self.idx >= len(self.paths):
            return None
        img = load_image(self.paths[self.idx], "train")[np.newaxis]   # 1,3,H,W /255
        self.idx += 1
        return {INPUT_NAME: img}


class HeadCalibReader:
    """分类头校准: 用融合模型的特征提取器算出 feature map 再喂给 head ONNX"""

    def __init__(self, fused, paths):
        self.fused = fused.cpu().eval()
        self.paths = paths
        self.idx = 0

    def get_next(self):
        if self.idx >= len(self.paths):
            return None
        img = load_image(self.paths[self.idx], "train")[np.newaxis]
        with torch.no_grad():
            feat = self.fused.features(torch.from_numpy(img)).numpy()
        self.idx += 1
        return {"features": feat}


# ---------------------------------------------------------------------------
# ONNX QDQ 图解析 (量化后的 ONNX 是唯一真值, FPGA 包与其严格一致)
# ---------------------------------------------------------------------------
def _fmt_scale(s):
    """scale 标量或 per-channel 数组 -> 紧凑字符串"""
    if s is None:
        return "-(fp32)"
    a = np.atleast_1d(np.asarray(s, dtype=np.float64))
    if a.size == 1:
        return f"{a[0]:.3e}"
    return f"{a.min():.3e}~{a.max():.3e} (per-channel x{a.size})"


def extract_quant_info(onnx_path):
    """从 QDQ INT8 ONNX 按序提取 Conv/Gemm 的量化参数与 int8/int32 数组.

    ORT 的 QDQ 图结构(实测): DQ 节点会被提到图前部; 权重/偏置是
    initializer -> DQ -> (可能经 Identity 重命名) -> 算子输入; 激活则是
    Q -> DQ -> 算子输入. 解析时必须穿透 Identity 与 Constant 节点.
    """
    import onnx
    from onnx import numpy_helper

    g = onnx.load(str(onnx_path)).graph
    inits = {i.name: numpy_helper.to_array(i) for i in g.initializer}
    producer, consumers = {}, {}
    for node in g.node:
        for o in node.output:
            producer[o] = node
        for inp in node.input:
            consumers.setdefault(inp, []).append(node)

    def tensor_array(t):
        """常量值: initializer / Constant 节点 / 穿透 Identity; 运行时张量返回 None"""
        seen = set()
        while t not in inits:
            n = producer.get(t)
            if n is None or id(n) in seen:
                return None
            seen.add(id(n))
            if n.op_type == "Identity":
                t = n.input[0]
            elif n.op_type == "Constant":
                for a in n.attribute:
                    if a.name == "value":
                        return numpy_helper.to_array(a)
                return None
            else:
                return None
        return inits[t]

    def dq_info(t):
        """t 由 DequantizeLinear 产生时: (来源tensor, scale, zp). 穿透 Identity 重命名."""
        seen = set()
        while True:
            n = producer.get(t)
            if n is None or id(n) in seen:
                return None
            seen.add(id(n))
            if n.op_type == "Identity":
                t = n.input[0]
                continue
            if n.op_type == "DequantizeLinear":
                return (n.input[0],
                        np.asarray(inits[n.input[1]]).astype(np.float64),
                        np.asarray(inits[n.input[2]]))
            return None

    def q_of_output(tensor):
        for c in consumers.get(tensor, []):
            if c.op_type == "QuantizeLinear":
                return (np.asarray(inits[c.input[1]]).astype(np.float64),
                        int(inits[c.input[2]]))
        return None

    def clean_attrs(node):
        out = {}
        for a in node.attribute:
            v = onnx.helper.get_attribute_value(a)
            out[a.name] = v.decode() if isinstance(v, bytes) else (
                v.tolist() if isinstance(v, np.ndarray) else v)
        return out

    def parse_common(node):
        """Conv/Gemm 共用: 权重 DQ + 激活输入 DQ + 输出 Q"""
        wi = dq_info(node.input[1])
        w = tensor_array(wi[0]) if wi else None
        ain = dq_info(node.input[0])          # 激活的 DQ 来源是 Q 输出(非 initializer), 只取 scale/zp
        aout = q_of_output(node.output[0])
        return {
            "w": w, "w_scale": wi[1] if wi else None, "w_zp": wi[2] if wi else None,
            "act_in_scale": ain[1] if ain else None,
            "act_in_zp": int(ain[2]) if ain else 0,
            "act_out_scale": aout[0] if aout else None,
            "act_out_zp": int(aout[1]) if aout else 0,
        }

    convs, heads = [], []
    for node in g.node:                       # ONNX 图为拓扑序, 与模型层序一致
        if node.op_type == "Conv":
            c = parse_common(node)
            c.update({"op": "Conv", "attrs": clean_attrs(node), "bias_int32": None,
                      "bias_float": None, "bias_scale": None, "bias_computed": False})
            if len(node.input) > 2:
                b = tensor_array(node.input[2])
                bi = dq_info(node.input[2])
                if bi is not None:
                    bsrc = tensor_array(bi[0])
                    if bsrc is not None and bsrc.dtype == np.int32:
                        c["bias_int32"] = bsrc
                        c["bias_scale"] = bi[1]
                    elif bsrc is not None:
                        c["bias_float"] = bsrc
                elif b is not None:
                    c["bias_float"] = b
            convs.append(c)
        elif node.op_type in ("Gemm", "MatMul"):
            h = parse_common(node)
            h["op"] = node.op_type
            heads.append(h)

    inp = None
    for c in consumers.get(g.input[0].name, []):
        if c.op_type == "QuantizeLinear":
            inp = {"scale": float(np.asarray(inits[c.input[1]]).astype(np.float64)),
                   "zp": int(inits[c.input[2]])}
    return convs, heads, inp


# ---------------------------------------------------------------------------
# ARM 侧分类头单独导出
# ---------------------------------------------------------------------------
class HeadOnly(nn.Module):
    def __init__(self, full):
        super().__init__()
        self.gap, self.classifier = full.gap, full.classifier

    def forward(self, x):
        return self.classifier(self.gap(x))


def export_head(fused, out_dir):
    fp32_path = out_dir / "head_fp32.onnx"
    out_ch = fused.classifier[1].in_features
    dummy = torch.randn(1, out_ch, C.INPUT_HEIGHT // 32, C.INPUT_WIDTH // 32)
    kwargs = dict(input_names=["features"], output_names=["logits"],
                  opset_version=C.ONNX_OPSET, do_constant_folding=True)
    try:
        torch.onnx.export(HeadOnly(fused).eval(), dummy, str(fp32_path), dynamo=False, **kwargs)
    except TypeError:      # torch 新版本可能已移除 dynamo 参数
        torch.onnx.export(HeadOnly(fused).eval(), dummy, str(fp32_path), **kwargs)
    return fp32_path


# ---------------------------------------------------------------------------
# BRAM 预算 (PG2K100: 144x36Kb = 632KB 块RAM + 793Kb 分布式RAM)
# ---------------------------------------------------------------------------
def bram_budget(layer_rows):
    """PG2K100 片上 RAM 预算: 144x36Kb=632KB BRAM + 99KB 分布式RAM.

    行缓冲按三种实现粒度给出:
      纯串行(逐层)   : 只有当前层的输入行缓冲在线, 峰值 = max(3*in_ch*W)
      块内流水(推荐) : 同 block 两个卷积同时在流水, 峰值 = max over blocks Σ(3*in_ch*W)
      全网络流水     : 所有层缓冲同时在线, 峰值 = Σ(3*in_ch*W)
    """
    w_kb = sum(r["params"] for r in layer_rows) / 1024
    bias_kb = sum(r["out_ch"] for r in layer_rows) * 4 / 1024
    lb3 = [3 * r["out_hw"][1] * r["in_ch"] / 1024 for r in layer_rows]
    lb2 = [2 * r["out_hw"][1] * r["in_ch"] / 1024 for r in layer_rows]
    # 块内 = 连续 CONVS_PER_BLOCK 层的缓冲之和
    k = C.CONVS_PER_BLOCK
    blocks3 = [sum(lb3[i:i + k]) for i in range(0, len(lb3), k)]
    blocks2 = [sum(lb2[i:i + k]) for i in range(0, len(lb2), k)]
    margin = 20.0   # FIFO/调度余量 KB
    serial = w_kb + bias_kb + max(lb3) + margin
    block_pipe = w_kb + bias_kb + (max(blocks3) if blocks3 else 0) + margin
    pipe3 = w_kb + bias_kb + sum(lb3) + margin
    pipe2 = w_kb + bias_kb + sum(lb2) + margin
    return {
        "bram_total_kb": 632.0, "dist_ram_kb": 99.1,
        "conv_weights_int8_kb": round(w_kb, 1),
        "conv_bias_int32_kb": round(bias_kb, 1),
        "line_buffer_layer_max_kb": round(max(lb3), 1),
        "line_buffer_block_max_kb": round(max(blocks3) if blocks3 else 0, 1),
        "line_buffer_3row_all_kb": round(sum(lb3), 1),
        "line_buffer_2row_all_kb": round(sum(lb2), 1),
        "serial_total_kb": round(serial, 1),
        "fits_serial": bool(serial <= 632),
        "block_pipeline_total_kb": round(block_pipe, 1),
        "fits_block_pipeline": bool(block_pipe <= 632),
        "full_pipeline_3row_total_kb": round(pipe3, 1),
        "fits_full_pipeline_3row": bool(pipe3 <= 632),
        "full_pipeline_2row_total_kb": round(pipe2, 1),
        "fits_full_pipeline_2row": bool(pipe2 <= 632),
    }


# ---------------------------------------------------------------------------
# 表格版量化参数 (给 FPGA/ARM 组的人看)
# ---------------------------------------------------------------------------
def write_quant_table(path, rows, convs, heads, inp_q, budget):
    lines = [
        "# INT8 量化参数表 (自动生成, 与 quant_params.json / weights_int8/ 严格一致)",
        "",
        f"- 模型: `{C.model_name()}`  输入: `1x3x{C.INPUT_HEIGHT}x{C.INPUT_WIDTH}`",
        f"- 输入量化: scale={inp_q['scale']:.6e}, zp={inp_q['zp']} (对称 int8)",
        f"- 片上 RAM 预算(推荐逐层串行/块内流水): 权重 {budget['conv_weights_int8_kb']}KB + 偏置 "
        f"{budget['conv_bias_int32_kb']}KB + 块内行缓冲 {budget['line_buffer_block_max_kb']}KB + 余量 20KB "
        f"= **{budget['block_pipeline_total_kb']}KB / 632KB** "
        f"({'✓ 放得下' if budget['fits_block_pipeline'] else '✗ 超出'})"
        f"（全网络流水中行缓冲升至 {budget['line_buffer_3row_all_kb']}KB, 合计 "
        f"{budget['full_pipeline_3row_total_kb']}KB, {'✓' if budget['fits_full_pipeline_3row'] else '✗ 需 2 行方案或分布式 RAM 分担'}）",
        "",
        "## FPGA 侧: 卷积层 (顺序执行, 逐层 requant)",
        "",
        "| 层 | 通道 in→out | 输出 H×W | act_in scale | weight scale (per-ch) | act_out scale | 偏置 |",
        "|---|---|---|---|---|---|---|",
    ]
    for i, (r, c) in enumerate(zip(rows, convs)):
        assert c["w"] is not None and r["params"] == c["w"].size, \
            f"conv{i:02d} 权重形状与模型不一致"
        bias = "int32" if c["bias_int32"] is not None else "无"
        if c.get("bias_computed"):
            bias += "(由float按累加器域换算)"
        lines.append(
            f"| conv{i:02d} | {r['in_ch']}→{r['out_ch']} | {r['out_hw'][0]}×{r['out_hw'][1]} "
            f"| {_fmt_scale(c['act_in_scale'])} | {_fmt_scale(c['w_scale'])} "
            f"| {_fmt_scale(c['act_out_scale'])} | {bias} |")
    lines += [
        "",
        "## ARM 侧: 分类头 (GAP 之后)",
        "",
        "| 层 | 权重形状 | act_in scale | weight scale | act_out scale |",
        "|---|---|---|---|---|",
    ]
    for i, h in enumerate(heads):
        lines.append(
            f"| fc{i+1} | {'x'.join(map(str, h['w'].shape))} "
            f"| {_fmt_scale(h['act_in_scale'])} | {_fmt_scale(h['w_scale'])} "
            f"| {_fmt_scale(h['act_out_scale'])} |")
    lines += [
        "",
        "## 定点数据流 (每层卷积)",
        "",
        "```",
        "acc32 = Σ(x_i8 · w_i8) + b_i32            # INT32 累加",
        "y_f   = acc32 × act_in_scale × w_scale[c]  # 反量化到 float (c=输出通道)",
        "y_i8  = clamp(round(y_f / act_out_scale), -128, 127)   # 再量化, 喂下一层",
        "```",
        "",
        "> 比对验收: 与 test_vectors/ 中逐层 `*_out_int8.npy` 差值 |Δ|≤1 为合格。",
        "",
    ]
    Path(path).write_text("\n".join(lines), encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# FP32 vs INT8 验证 (T1 修复: 独立样本 + 双侧同用 ORT 部署运行时)
# ---------------------------------------------------------------------------
def _cls_np(result):
    """ORT 输出 -> 仅取严重度 logits (双头模型输出为 list[severity, type])"""
    out = result[0] if isinstance(result, (tuple, list)) else result
    return np.asarray(out)


def verify(int8_onnx, n_verify, calib_used, labeled_paths=None, labels=None):
    """一致性验证: 样本来自独立 val 池(不再与校准同源), FP32 侧直接跑
    model_fp32_fused.onnx(与部署同运行时, 300 张约 90s)."""
    import onnxruntime as ort

    paths, src = verify_paths(n_verify, exclude=calib_used)
    sess8 = ort.InferenceSession(str(int8_onnx), providers=["CPUExecutionProvider"])
    sess32 = ort.InferenceSession(str(C.QUANT_EXPORT_DIR / "model_fp32_fused.onnx"),
                                  providers=["CPUExecutionProvider"])
    max_diff, agree = 0.0, 0
    for p in paths:
        x = load_image(p, "val")[np.newaxis]
        f32 = _cls_np(sess32.run(None, {INPUT_NAME: x}))
        i8 = _cls_np(sess8.run(None, {INPUT_NAME: x}))
        max_diff = max(max_diff, float(np.abs(f32 - i8).max()))
        agree += int(f32.argmax() == i8.argmax())
    report = {"n_verify": len(paths), "verify_source": src,
              "max_abs_logit_diff": round(max_diff, 5),
              "argmax_agree": round(agree / max(1, len(paths)), 5)}

    if labeled_paths and labels is not None and len(labels) == len(labeled_paths):
        n = min(300, len(labeled_paths))
        correct = {"fp32": 0, "int8": 0}
        for k in range(n):
            x = load_image(labeled_paths[k], "test")[np.newaxis]
            r32 = _cls_np(sess32.run(None, {INPUT_NAME: x}))
            r8 = _cls_np(sess8.run(None, {INPUT_NAME: x}))
            correct["fp32"] += int(r32.argmax() == labels[k])
            correct["int8"] += int(r8.argmax() == labels[k])
        report["subset_accuracy"] = {k: round(v / n, 4) for k, v in correct.items()}
    return report


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(C.MODEL_DIR / "best_model.pt"))
    ap.add_argument("--n-verify", type=int, default=C.N_VERIFY_DEFAULT,
                    help="独立验证样本数(默认取 config.N_VERIFY_DEFAULT=%d)" % C.N_VERIFY_DEFAULT)
    args = ap.parse_args()

    try:
        import onnxruntime  # noqa: F401
    except ImportError:
        raise SystemExit("缺少 onnxruntime: python -m pip install onnxruntime")
    from onnxruntime.quantization import CalibrationMethod, QuantFormat, QuantType

    out = C.QUANT_EXPORT_DIR
    out.mkdir(parents=True, exist_ok=True)
    install_streaming_calibration_patch()

    def quant_extra(symmetric):
        extra = {"ActivationSymmetric": symmetric}
        if C.CALIB_METHOD == "Percentile":
            extra["CalibPercentile"] = float(C.CALIB_PERCENTILE)
        return extra

    # 1) 加载 -> BN 融合
    model, _ = M.load_model(args.model)
    fused = M.fuse_bn_into_convs(model)
    rows = M.layer_table(fused)
    fp32_onnx = out / "model_fp32_fused.onnx"
    M.export_fp32_onnx(fused, fp32_onnx)

    # 2) ARM 分类头 FP32 单独导出
    head_fp32 = export_head(fused, out)
    print(f"[ONNX] ARM 分类头 FP32: {head_fp32}")

    # 3) INT8 静态量化 (QDQ, 权重 per-channel s8, 激活 per-tensor s8 对称)
    int8_onnx = out / "model_int8.onnx"
    calib_used = calib_paths(C.CALIB_SAMPLES)
    print(f"[校准] method={C.CALIB_METHOD} samples={len(calib_used)} pool={C.CALIB_POOL}"
          + (f" percentile={C.CALIB_PERCENTILE}" if C.CALIB_METHOD == "Percentile" else ""))
    quantize_static_ascii(
        fp32_onnx, int8_onnx,
        calibration_data_reader=CalibReader(calib_used),
        quant_format=QuantFormat.QDQ,
        op_types_to_quantize=C.QUANT_OP_TYPES,
        per_channel=True,
        activation_type=QuantType.QInt8, weight_type=QuantType.QInt8,
        calibrate_method=getattr(CalibrationMethod, C.CALIB_METHOD),
        extra_options=quant_extra(C.ACTIVATION_SYMMETRIC),
    )
    print(f"[INT8] 静态量化完成: {int8_onnx} ({int8_onnx.stat().st_size/1024:.0f} KB)")

    head_int8 = out / "head_int8.onnx"
    quantize_static_ascii(
        head_fp32, head_int8,
        calibration_data_reader=HeadCalibReader(fused, calib_used[:min(64, len(calib_used))]),
        quant_format=QuantFormat.QDQ, op_types_to_quantize=["Gemm", "MatMul"],
        per_channel=True, activation_type=QuantType.QInt8, weight_type=QuantType.QInt8,
        calibrate_method=getattr(CalibrationMethod, C.CALIB_METHOD),
        extra_options=quant_extra(True),
    )
    print(f"[INT8] ARM 分类头量化完成: {head_int8}")

    # 4) 解析量化图 -> FPGA 权重包 + 参数 json + 表格 md
    convs, heads, inp_q = extract_quant_info(int8_onnx)
    if len(convs) != len(rows):
        raise RuntimeError(f"ONNX 中 Conv 层数 {len(convs)} != 模型 {len(rows)}, 解析异常")
    wdir = out / "weights_int8"
    wdir.mkdir(exist_ok=True)
    for i, c in enumerate(convs):
        if c["w"] is None or c["act_in_scale"] is None or c["act_out_scale"] is None:
            raise RuntimeError(f"conv{i:02d} 量化参数解析不完整, 请检查量化流程")
        np.save(wdir / f"conv{i:02d}_w_int8.npy", c["w"].astype(np.int8))
        # ORT 未量化的 float 偏置 -> 换算到累加器域 int32, 与量化偏置统一数据流:
        # b_acc = round(b_f / (act_in_scale * w_scale[c]))  (即 ORT 量化偏置的同一公式)
        if c["bias_int32"] is None and c["bias_float"] is not None:
            acc_scale = (c["act_in_scale"].reshape(-1) * c["w_scale"].reshape(-1))[:c["bias_float"].size]
            c["bias_int32"] = np.round(c["bias_float"] / acc_scale).astype(np.int32)
            c["bias_scale"] = acc_scale
            c["bias_computed"] = True
        if c["bias_int32"] is not None:
            np.save(wdir / f"conv{i:02d}_b_int32.npy", c["bias_int32"].astype(np.int32))

    quant_params = {
        "input": inp_q,
        "conv_layers": [{
            "name": f"conv{i:02d}", "op": c["op"], "attrs": c["attrs"],
            "w_shape": list(c["w"].shape),
            "act_in_scale": c["act_in_scale"].tolist(), "act_in_zp": c["act_in_zp"],
            "weight_scale": c["w_scale"].tolist(), "weight_zp": c["w_zp"].tolist(),
            "act_out_scale": c["act_out_scale"].tolist(), "act_out_zp": c["act_out_zp"],
            "bias_int32": c["bias_int32"].tolist() if c["bias_int32"] is not None else None,
            "bias_scale": c["bias_scale"].tolist() if c["bias_scale"] is not None else None,
            "bias_computed": c["bias_computed"],
        } for i, c in enumerate(convs)],
        "head_layers": [{
            "name": f"fc{i+1}", "op": h["op"], "w_shape": list(h["w"].shape),
            "act_in_scale": h["act_in_scale"].tolist() if h["act_in_scale"] is not None else None,
            "weight_scale": h["w_scale"].tolist(),
            "act_out_scale": h["act_out_scale"].tolist() if h["act_out_scale"] is not None else None,
        } for i, h in enumerate(heads)],
    }
    (out / "quant_params.json").write_text(
        json.dumps(quant_params, ensure_ascii=False, indent=1), encoding="utf-8")
    budget = bram_budget(rows)
    write_quant_table(out / "quant_params_table.md", rows, convs, heads, inp_q, budget)
    print(f"[FPGA] quant_params.json + quant_params_table.md + weights_int8/ "
          f"({len(convs)} conv + {len(heads)} fc 层)")

    # 5) 预处理规格 + FPGA 结构规范 v1.2
    spec = {
        "original_hw": [C.ORIG_HEIGHT, C.ORIG_WIDTH],
        "input_hw": [C.INPUT_HEIGHT, C.INPUT_WIDTH],
        "resize": f"PIL {C.RESIZE_INTERPOLATION} (FPGA 需实现等效插值)",
        "normalize": "x/255 -> float32 [0,1]",
        "layout": "NCHW, RGB, 行优先",
        "input_quant": inp_q,
        "augmentation": "推理侧禁止任何增强(训练增强仅水平翻转/亮度对比度, 不影响部署)",
    }
    (out / "preprocess_spec.json").write_text(json.dumps(spec, ensure_ascii=False, indent=2),
                                              encoding="utf-8")

    fpga_spec = {
        "version": "1.3",
        "board": {"fpga": "紫光同创 PG2K100 (Kosmo-2 SoC)",
                  "pa": {"le": 85760, "lut": 53600, "bram_kb": 632.0, "apm": 256},
                  "pu": "dual Cortex-A53 @1GHz (NEON)", "ddr": "板载 16bit DDR3 (PU 控制器)"},
        "split": {"fpga_features": "conv00..conv09 (QDQ INT8, 权重片上驻留)",
                  "arm_head": f"GAP + fc1 + fc2, 见 head_int8.onnx "
                              f"(输出 {'5 维: 3 严重度 + 2 类型存在性(MTL/CRC)' if model.type_head else '3 维严重度'})"},
        "input": spec, "layers": rows,
        "bram_budget": budget,
        "dataflow": "逐层串行; 行缓冲流水; INT32 累加; 逐层 requant: "
                    "y_f = acc32 * (act_in_scale * w_scale[c]); "
                    "y_i8 = clamp(round(y_f / act_out_scale), -128, 127)",
        "weight_streaming_alternative": "若改用 [32,64,128,256,512](4.4MB), 片上放不下, "
                                        "需 PA 经 AXI 从 DDR3 双缓冲流送权重, 算力/带宽另评",
        "deliverables": ["model_int8.onnx", "head_int8.onnx", "quant_params.json",
                         "quant_params_table.md", "weights_int8/", "preprocess_spec.json",
                         "test_vectors/"],
    }
    (out / "fpga_architecture_spec.json").write_text(json.dumps(
        fpga_spec, ensure_ascii=False, indent=2), encoding="utf-8")

    # 6) FP32 vs INT8 一致性验证 (测试集有真实标签来源才算精度, 否则只算一致性)
    labeled_paths, labels = None, None
    test_files = [str(p) for p in iter_image_files(C.TEST_IMAGE_DIR)] if C.TEST_IMAGE_DIR else []
    has_test_label = ((C.TEST_LABEL_JSON and Path(C.TEST_LABEL_JSON).exists())
                      or (C.TEST_LABEL_DIR and Path(C.TEST_LABEL_DIR).exists()))
    if test_files and has_test_label:
        from dataset import build_labels
        labeled_paths = test_files
        lbl = build_labels([Path(p).name for p in test_files], C.TEST_LABEL_JSON,
                           C.TEST_LABEL_DIR, "test")
        labels = lbl[0] if isinstance(lbl, tuple) else lbl
    rep = verify(int8_onnx, args.n_verify, calib_used, labeled_paths, labels)
    rep["calibration"] = {
        "method": C.CALIB_METHOD,
        "samples": len(calib_used),
        "pool": C.CALIB_POOL,
        "percentile": C.CALIB_PERCENTILE if C.CALIB_METHOD == "Percentile" else None,
        "op_types": C.QUANT_OP_TYPES,
    }
    rep["baseline_before_T1"] = {   # 修复前基线留档(2026-09): 用于验收对照
        "quantization_report_argmax_agree_64_trainpool": 0.953125,   # 09-13, 循环验证口径
        "compare_int8_test3000_argmax_agree": 0.951,                 # 09-15, 独立 test 池
        "spotcheck_26img_agree": "9/26 (hi_conf_flips=12, 全 severity-0 桶)",  # 09-29 复测交付
        "acceptance": "compare_int8 --split test --n 3000 argmax_agree >= 0.98",
    }
    rep["sizes_kb"] = {
        "fp32_fused_onnx": round(fp32_onnx.stat().st_size / 1024, 1),
        "int8_onnx": round(int8_onnx.stat().st_size / 1024, 1),
        "conv_weights_int8": budget["conv_weights_int8_kb"],
    }
    rep["bram_budget"] = budget
    (out / "quantization_report.json").write_text(json.dumps(
        rep, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[验证] INT8 vs FP32: {json.dumps(rep, ensure_ascii=False)}")


if __name__ == "__main__":
    main()
