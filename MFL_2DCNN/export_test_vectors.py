# -*- coding: utf-8 -*-
"""
FPGA 逐层测试向量: python export_test_vectors.py [--model ...] [--samples 3] [--from-existing]

对若干样本逐层记录: 卷积输入/输出的 FP32(半精度存) 与 INT8(按 quant_params.json 的 scale)
[模型侧修正 2026-10-15, 起因=FPGA 成员新向量审计] 抓取必须在 fuse_bn_into_convs 折叠 BN 之后的
图上进行: 原实现直接用未折叠模型, 钩子抓到 pre-BN 张量 —— *_out 与 int8 链层边界(权重已折叠 BN)
不一致, *_in 与 *_out 之间隔逐通道仿射, 逐层对拍不可用。折叠后精确关系: in_i = relu((pool) out_{i-1})。
FPGA 逐层比对: int8 输出与向量逐元素 |diff|<=1 视为合格.
--from-existing: 数据盘离线时, 复用已交付 sample_* 目录的 input_f32.npy 作为输入(样本与输入不变).
产出: output/test_vectors/sample_k_xxx/... + manifest.json + README_FPGA.txt
"""

import argparse
import json
from pathlib import Path

import numpy as np
import torch

import config as C
import model as M
from dataset import iter_image_files, load_image


def quantize_int8(x, scale):
    return np.clip(np.round(x / scale), -128, 127).astype(np.int8)


def pick_samples(n):
    """优先每类各选 1 张(需标签), 不足则按序补齐"""
    files = [str(p) for p in iter_image_files(C.TRAIN_IMAGE_DIR)]
    from dataset import build_labels
    lbl = build_labels([Path(p).name for p in files], C.TRAIN_LABEL_JSON,
                       C.TRAIN_LABEL_DIR, "train")
    labels = lbl[0] if isinstance(lbl, tuple) else lbl
    chosen, seen = [], set()
    for cls in range(C.NUM_CLASSES):
        idx = np.where(labels == cls)[0]
        if len(idx):
            chosen.append(files[int(idx[0])])
            seen.add(int(idx[0]))
    for i, f in enumerate(files):
        if len(chosen) >= n:
            break
        if i not in seen:
            chosen.append(f)
    return chosen[:n], (labels if len(chosen) else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(C.MODEL_DIR / "best_model.pt"))
    ap.add_argument("--samples", type=int, default=3)
    ap.add_argument("--from-existing", action="store_true",
                    help="离线回退: 复用已交付 sample_* 目录的 input_f32.npy 作为输入")
    args = ap.parse_args()

    qfile = C.QUANT_EXPORT_DIR / "quant_params.json"
    if not qfile.exists():
        raise SystemExit("请先运行 quantize_export.py 生成 quant_params.json")
    qp = json.loads(qfile.read_text(encoding="utf-8"))
    # quant_params.json 为扁平 schema: act_in_scale/act_out_scale 均为标量(对称量化 zp=0)
    scales_in = [float(l["act_in_scale"]) for l in qp["conv_layers"]]
    scales_out = [float(l["act_out_scale"]) for l in qp["conv_layers"]]
    input_scale = float(qp["input"]["scale"])

    net, _ = M.load_model(args.model)
    fused = M.fuse_bn_into_convs(net).cpu().eval()   # [审计修正] BN 折叠后再抓取:
    # 原实现未折叠 —— 钩子抓到 pre-BN 张量, 与 int8 链层边界不一致
    # (实测: in=relu(BN(out)) 精确成立 max|Δ|=1.9e-06; in=relu(out) 偏差 59.97)

    layer_names = [n for n, _, _ in M.conv_layers(fused)]
    captures = {}   # layer_name -> dict(in=, out=)

    def make_hook(name):
        def hook(mod, inp, out):
            captures[name] = {"in": inp[0].detach().numpy().astype(np.float32),
                              "out": out.detach().numpy().astype(np.float32)}
        return hook

    for name, mod, _bn in M.conv_layers(fused):
        mod.register_forward_hook(make_hook(name))

    if args.from_existing:
        prev = sorted(p for p in C.TEST_VECTOR_DIR.glob("sample_*") if p.is_dir())
        if not prev:
            raise SystemExit("--from-existing 需要已交付的 sample_* 目录存在")
        inputs = [(p.name.split("_", 2)[2], np.load(p / "input_f32.npy").astype(np.float32))
                  for p in prev]
    else:
        inputs = [(Path(p).stem, load_image(p, "train")[np.newaxis])
                  for p in pick_samples(args.samples)[0]]
    out_root = C.TEST_VECTOR_DIR
    out_root.mkdir(exist_ok=True)
    manifest = {"model": str(args.model), "profile": fused.profile,
                "layer_names": layer_names,
                "input_scale": input_scale,
                "conv_in_scale": scales_in, "conv_out_scale": scales_out,
                "graph": "fuse_bn_into_convs 折叠后抓取(与 ORT 融合图同构); "
                         "*_out = conv 层输出(pre-ReLU/pre-Pool, = int8 链该层 requant 前的 f32 域); "
                         "*_in = 下一 conv 输入; 精确关系 in_i = relu((pool_i-1) out_(i-1)) (f32 级)",
                "layers_table": [
                    {"layer": n, "in_scale": scales_in[li], "out_scale": scales_out[li],
                     "relu_after": True, "pool_after": (li % 2 == 1),
                     "boundary_ratio_to_next": (scales_out[li] / scales_in[li + 1])
                                               if li + 1 < len(layer_names) else None}
                    for li, n in enumerate(layer_names)],
                "preprocess": "BILINEAR 缩放到 %dx%d, /255 (与 preprocess_spec.json 一致)" % (
                    C.INPUT_WIDTH, C.INPUT_HEIGHT),
                "samples": []}

    for k, (stem, x) in enumerate(inputs):
        captures.clear()
        with torch.no_grad():
            out = fused(torch.from_numpy(x))
        logits = (out[0] if isinstance(out, (tuple, list)) else out).numpy()[0]
        sdir = out_root / f"sample_{k}_{stem}"
        sdir.mkdir(exist_ok=True)
        np.save(sdir / "input_f32.npy", x.astype(np.float16))
        np.save(sdir / "input_int8.npy", quantize_int8(x, input_scale))
        layers_meta = []
        for li, name in enumerate(layer_names):
            d = captures[name]
            np.save(sdir / f"{name}_in_f32.npy", d["in"].astype(np.float16))
            np.save(sdir / f"{name}_out_f32.npy", d["out"].astype(np.float16))
            np.save(sdir / f"{name}_in_int8.npy", quantize_int8(d["in"], scales_in[li]))
            np.save(sdir / f"{name}_out_int8.npy", quantize_int8(d["out"], scales_out[li]))
            layers_meta.append({"layer": name, "in_shape": list(d["in"].shape),
                                "out_shape": list(d["out"].shape)})
        manifest["samples"].append({"dir": sdir.name, "image": stem,
                                    "logits_f32": logits.tolist(),
                                    "layers": layers_meta})
        print(f"[向量] {sdir.name}: {len(layer_names)} 层已导出")

    (out_root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                                            encoding="utf-8")
    (out_root / "README_FPGA.txt").write_text(
        "FPGA 逐层测试向量说明 (v2, BN 折叠图抓取 — 2026-10-15 审计修正版)\n"
        "====================\n"
        f"模型: {manifest['model']}  配比: {manifest['profile']}\n"
        "图语义: BN 已折叠进 conv 权重(fuse_bn_into_convs), 与 ORT 融合图/int8 链同构。\n"
        "  *_out = 第 XX 层 conv 的输出(pre-ReLU/pre-Pool) = int8 链该层 requant 前的 f32 域;\n"
        "  *_in  = 第 XX 层 conv 的输入 = relu((pool) 前层 out) —— f32 级精确成立,\n"
        "          同 scale 边界(int8)为逐元素直通, 异 scale 边界满足 Mc=s_out/s_in 比例关系;\n"
        "  末层: conv09_out 之后接 ReLU+MaxPool 得最终 feat(96x15x32, 全非负)。\n"
        "每层算子序列(relu_after/pool_after/边界比例)见 manifest.json 的 layers_table,\n"
        "层配置生成器可直接照抄, 无需推断。\n"
        "每个 sample_* 目录:\n"
        "  input_f32.npy / input_int8.npy     网络输入 (1,3,480,1024), int8 按 input_scale 量化\n"
        "  convXX_in_f32.npy / convXX_in_int8.npy   第 XX 层卷积输入 (f32 存为 float16)\n"
        "  convXX_out_f32.npy / convXX_out_int8.npy 第 XX 层卷积输出\n"
        "int8 量化规则: int8 = clip(round(f32 / scale), -128, 127), scale 见 manifest.json\n"
        "  (f32 与 int8 文件自洽受 float16 存储噪声影响, 一致率 ~99.9%, 残余 ±1 属正常)\n"
        "NPY 格式: numpy 标准 \\x93NUMPY 魔数(np.save 默认), np.load 直接可读。\n"
        "比对标准: FPGA 每层 int8 输出与 *_out_int8.npy 逐元素 |diff| <= 1 为合格;\n"
        "最终 logits 与 manifest 中 logits_f32 反量化后误差 < 0.1 为合格.\n"
        "注: 向量为 FP32 图参考(FP32 前向 + 按 ORT scale 量化), 与纯 int8 链逐位对比会带\n"
        "输入量化与累加域的 ±1~2 固有差; 位级(零差)对拍请用 fpga_sim.py 定点链。\n",
        encoding="utf-8")
    print(f"[完成] {out_root} (manifest.json + README_FPGA.txt)")


if __name__ == "__main__":
    main()
