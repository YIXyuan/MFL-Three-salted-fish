# -*- coding: utf-8 -*-
"""
生成表格化模型结构文档: python export_structure.py [--out output/MODEL_STRUCTURE.md]

给 FPGA / ARM 组看的 Markdown 表格版结构说明, 纯架构信息(无需先训练).
训练+量化之后, 各层的具体 scale 见 output/quant_export/quant_params_table.md.
"""

import argparse

import config as C
import model as M


def macs_of(profile):
    """整模型卷积 MACs (乘加次数)/帧"""
    h, w = C.INPUT_HEIGHT, C.INPUT_WIDTH
    in_ch, total = 3, 0
    for out_ch in profile:
        for _ in range(C.CONVS_PER_BLOCK):
            total += h * w * out_ch * in_ch * 9
            in_ch = out_ch
        h, w = h // 2, w // 2
    return total


def layer_md_rows(profile):
    net = M.MFLCNN(profile=profile)
    rows = M.layer_table(net)
    lines = []
    block = 0
    for i, r in enumerate(rows):
        if i % C.CONVS_PER_BLOCK == 0:
            block += 1
            lines.append(f"| — **Block {block}** — |||||||")
        lines.append(
            f"| conv{i:02d} | Conv2D | {r['in_ch']}→{r['out_ch']} | {r['kernel']}×{r['kernel']} "
            f"| {r['stride']} | 1 | {r['out_hw'][0]}×{r['out_hw'][1]} "
            f"| {r['params']:,} | {r['int8_kb']:.1f} |")
        if (i + 1) % C.CONVS_PER_BLOCK == 0:
            lines.append(f"| pool{block} | MaxPool 2×2 s2 | {r['out_ch']} | 2×2 | 2 | 0 "
                         f"| {r['out_hw'][0]//2}×{r['out_hw'][1]//2} | — | — |")
    return lines, rows


def build_md():
    profile = C.MODEL_PROFILE
    conv_lines, rows = layer_md_rows(profile)
    from quantize_export import bram_budget
    bud = bram_budget(rows)
    fc1_in = profile[-1]
    fc1_p, fc2_p = fc1_in * C.FC_HIDDEN, C.FC_HIDDEN * C.NUM_CLASSES
    macs = macs_of(profile)
    conv_params = sum(r["params"] for r in rows)
    head_dim = C.NUM_CLASSES + (2 if C.ENABLE_TYPE_HEAD else 0)
    out_desc = (f"{C.NUM_CLASSES} 维严重度 logits（softmax 后三类概率）"
                + (" + 2 维腐蚀类型存在性（MTL/CRC，sigmoid）" if C.ENABLE_TYPE_HEAD else ""))
    head_desc = (f"GAP → fc1({fc1_in}→{C.FC_HIDDEN}) → ReLU → fc2({C.FC_HIDDEN}→{head_dim}) → "
                 + ("softmax + sigmoid" if C.ENABLE_TYPE_HEAD else "softmax"))
    head_note = ("" if not C.ENABLE_TYPE_HEAD else
                 "\n> 类型双头已启用：fc2 输出多 2 维（MTL/CRC 存在性，BCE 训练）；"
                 "FPGA 侧结构完全不变，仅 ARM 后处理多一个 sigmoid。")

    # 候选配比对比
    cand_lines = []
    for p, note in [([16, 32, 48, 96, 96], "最保守"),
                    ([16, 32, 64, 96, 96], "**默认**"),
                    ([16, 32, 64, 128, 128], "容量最大"),
                    ([32, 64, 128, 256, 512], "豆包初版")]:
        net = M.MFLCNN(profile=p)
        rr = M.layer_table(net)
        wkb = sum(r["params"] for r in rr) / 1024
        mk = max(r["int8_kb"] for r in rr)
        b = bram_budget(rr)
        fit = "✓ 片上驻留" if b["fits_block_pipeline"] else "✗ 需 DDR3 权重流送"
        cand_lines.append(f"| [{'/'.join(map(str, p))}]{'  ← ' + note if note else ''} "
                          f"| {wkb:.0f} KB | {mk:.0f} KB | {macs_of(p)/1e9:.1f} G | {fit} |")

    md = f"""# MFL 2D-CNN 模型结构说明（{C.model_name()}）

> 本文档由 `export_structure.py` 自动生成，随 `config.py` 的 `MODEL_PROFILE` 变化。
> 训练后各层量化 scale 见 `output/quant_export/quant_params_table.md`（同为表格）。

## 1. 总览

| 项目 | 内容 |
|---|---|
| 任务 | MFL 伪彩图 → 图像级三分类：normal / light_corrosion / severe_corrosion |
| 输入 | `1×3×{C.INPUT_HEIGHT}×{C.INPUT_WIDTH}` (RGB, /255 归一化, NCHW) |
| 原图 | {C.ORIG_WIDTH}×{C.ORIG_HEIGHT}，BILINEAR 缩放到 {C.INPUT_WIDTH}×{C.INPUT_HEIGHT} |
| 输出 | {out_desc} |
| 卷积 MACs/帧 | {macs/1e9:.2f} G ({macs:,}) |
| INT8 卷积权重 | {conv_params/1024:.0f} KB（{conv_params:,} 参数） |
| 部署目标 | 紫光同创 PG2K100：PA(FPGA) 跑卷积，PU(双核 A53) 跑分类头 |

## 2. 推理分工（FPGA / ARM 边界）

| 端 | 模块 | 内容 | 数据 |
|---|---|---|---|
| **FPGA (PA)** | `features` | conv00…conv{len(rows)-1:02d} + 5×MaxPool，全部 INT8 定点 | 权重 {conv_params/1024:.0f} KB 片上 BRAM 驻留 |
| **FPGA→ARM** | feature map | `1×{profile[-1]}×{C.INPUT_HEIGHT//32}×{C.INPUT_WIDTH//32}` INT8，经 AXI 送 DDR | {profile[-1]*C.INPUT_HEIGHT//32*C.INPUT_WIDTH//32/1024:.1f} KB/帧 || **ARM (PU)** | `head` | {head_desc} | INT8 权重 {(fc1_p + fc2_p + C.FC_HIDDEN * 2)/1024:.1f} KB，NEON 单帧微秒级 |
{head_note}

## 3. FPGA 侧逐层结构（顺序执行）

| 层 | 算子 | 通道 | 卷积核 | 步长 | 填充 | 输出 H×W | 参数量 | INT8 体积 |
|---|---|---|---|---|---|---|---|---|
{chr(10).join(conv_lines)}

> BN 已在量化前融合进卷积（权重+偏置），上表即融合后的最终结构；
> 推理数据流：`x_i8·w_i8 → INT32 累加 → requant → INT8`，逐层公式见第 5 节。

## 4. PG2K100 片上 RAM 预算（BRAM 共 144×36Kb = 632KB，另分布式 RAM 99KB）

| 实现方案 | 权重 | 偏置 | 行缓冲 | +余量 | **合计 / 632KB** | 结论 |
|---|---|---|---|---|---|---|
| **逐层串行（推荐起步）** | {bud['conv_weights_int8_kb']} KB | {bud['conv_bias_int32_kb']} KB | {bud['line_buffer_layer_max_kb']} KB（单层峰值） | 20 KB | **{bud['serial_total_kb']} KB** | {'✓' if bud['fits_serial'] else '✗'} |
| **块内双卷积流水（推荐）** | {bud['conv_weights_int8_kb']} KB | {bud['conv_bias_int32_kb']} KB | {bud['line_buffer_block_max_kb']} KB（块峰值） | 20 KB | **{bud['block_pipeline_total_kb']} KB** | {'✓' if bud['fits_block_pipeline'] else '✗'} |
| 全网络流水（3 行缓冲） | {bud['conv_weights_int8_kb']} KB | {bud['conv_bias_int32_kb']} KB | {bud['line_buffer_3row_all_kb']} KB（所有层同时） | 20 KB | **{bud['full_pipeline_3row_total_kb']} KB** | {'✓' if bud['fits_full_pipeline_3row'] else '✗ 超出，改 2 行=' + str(bud['full_pipeline_2row_total_kb']) + 'KB ' + ('✓' if bud['fits_full_pipeline_2row'] else '✗')} |

> 输入帧（1.4MB）与各 block 间特征图（1~2MB）不入 BRAM：整网按行流式处理，
> 帧数据从 DDR3 经 AXI 流入、GAP 前的 feature map 流回 DDR。权重全部常驻片上。
> 单层最大权重 {max(r['int8_kb'] for r in rows):.0f} KB
>（conv{(max(range(len(rows)), key=lambda i: rows[i]['int8_kb'])):02d}），可整层装入单 bank 组。

## 5. 候选配比对比（config.py 一行切换，改后需重新训练+量化）

| MODEL_PROFILE | INT8 卷积权重 | 最大单层 | MACs/帧 | 632KB 结论 |
|---|---|---|---|---|
{chr(10).join(cand_lines)}

## 6. 定点数据流（每层卷积）

```
acc32 = Σ(x_i8 · w_i8) + b_i32              # INT32 累加 (APM)
y_f   = acc32 × act_in_scale × w_scale[c]    # 反量化, c = 输出通道 (per-channel)
y_i8  = clamp(round(y_f / act_out_scale), -128, 127)   # requant 喂下一层
```

激活对称 int8（zp=0），无偏移修正，累加器逻辑最简。
验收：`output/test_vectors/` 逐层与 `*_out_int8.npy` 比对 |Δ|≤1。

## 7. 交付物清单（训练 + `quantize_export.py` 之后）

| 文件 | 内容 | 给谁 |
|---|---|---|
| `quant_params.json` / `quant_params_table.md` | 每层 scale/zp/偏置（json 机器读，md 人读） | FPGA |
| `weights_int8/*.npy` | 每层 INT8 权重 + INT32 偏置 | FPGA |
| `preprocess_spec.json` | BILINEAR→{C.INPUT_WIDTH}×{C.INPUT_HEIGHT}→/255 规格与输入 scale | FPGA |
| `fpga_architecture_spec.json` | 本文档的机器可读版 + 预算表 | FPGA |
| `test_vectors/` | 逐层 FP32/INT8 测试向量 + manifest | FPGA |
| `model_int8.onnx` | QDQ 全模型（onnxruntime 可直接跑, 精度对照用） | ARM |
| `head_int8.onnx` | 分类头单独 INT8（配 FPGA feature map） | ARM |
"""
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(C.OUTPUT_DIR / "MODEL_STRUCTURE.md"))
    args = ap.parse_args()
    md = build_md()
    from pathlib import Path
    Path(args.out).write_text(md, encoding="utf-8")
    print(md)
    print(f"[完成] 已写入 {args.out}")


if __name__ == "__main__":
    main()
