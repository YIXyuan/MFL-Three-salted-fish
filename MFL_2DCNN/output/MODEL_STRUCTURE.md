# MFL 2D-CNN 模型结构说明（mfl2d_p16_32_64_96_96）

> 本文档由 `export_structure.py` 自动生成，随 `config.py` 的 `MODEL_PROFILE` 变化。
> 训练后各层量化 scale 见 `output/quant_export/quant_params_table.md`（同为表格）。

## 1. 总览

| 项目 | 内容 |
|---|---|
| 任务 | MFL 伪彩图 → 图像级三分类：normal / light_corrosion / severe_corrosion |
| 输入 | `1×3×480×1024` (RGB, /255 归一化, NCHW) |
| 原图 | 5000×2400，BILINEAR 缩放到 1024×480 |
| 输出 | 3 维严重度 logits（softmax 后三类概率） |
| 卷积 MACs/帧 | 6.12 G (6,122,373,120) |
| INT8 卷积权重 | 367 KB（375,984 参数） |
| 部署目标 | 紫光同创 PG2K100：PA(FPGA) 跑卷积，PU(双核 A53) 跑分类头 |

## 2. 推理分工（FPGA / ARM 边界）

| 端 | 模块 | 内容 | 数据 |
|---|---|---|---|
| **FPGA (PA)** | `features` | conv00…conv09 + 5×MaxPool，全部 INT8 定点 | 权重 367 KB 片上 BRAM 驻留 |
| **FPGA→ARM** | feature map | `1×96×15×32` INT8，经 AXI 送 DDR | 45.0 KB/帧 || **ARM (PU)** | `head` | GAP → fc1(96→256) → ReLU → fc2(256→3) → softmax | INT8 权重 25.2 KB，NEON 单帧微秒级 |


## 3. FPGA 侧逐层结构（顺序执行）

| 层 | 算子 | 通道 | 卷积核 | 步长 | 填充 | 输出 H×W | 参数量 | INT8 体积 |
|---|---|---|---|---|---|---|---|---|
| — **Block 1** — |||||||
| conv00 | Conv2D | 3→16 | 3×3 | 1 | 1 | 480×1024 | 432 | 0.4 |
| conv01 | Conv2D | 16→16 | 3×3 | 1 | 1 | 480×1024 | 2,304 | 2.2 |
| pool1 | MaxPool 2×2 s2 | 16 | 2×2 | 2 | 0 | 240×512 | — | — |
| — **Block 2** — |||||||
| conv02 | Conv2D | 16→32 | 3×3 | 1 | 1 | 240×512 | 4,608 | 4.5 |
| conv03 | Conv2D | 32→32 | 3×3 | 1 | 1 | 240×512 | 9,216 | 9.0 |
| pool2 | MaxPool 2×2 s2 | 32 | 2×2 | 2 | 0 | 120×256 | — | — |
| — **Block 3** — |||||||
| conv04 | Conv2D | 32→64 | 3×3 | 1 | 1 | 120×256 | 18,432 | 18.0 |
| conv05 | Conv2D | 64→64 | 3×3 | 1 | 1 | 120×256 | 36,864 | 36.0 |
| pool3 | MaxPool 2×2 s2 | 64 | 2×2 | 2 | 0 | 60×128 | — | — |
| — **Block 4** — |||||||
| conv06 | Conv2D | 64→96 | 3×3 | 1 | 1 | 60×128 | 55,296 | 54.0 |
| conv07 | Conv2D | 96→96 | 3×3 | 1 | 1 | 60×128 | 82,944 | 81.0 |
| pool4 | MaxPool 2×2 s2 | 96 | 2×2 | 2 | 0 | 30×64 | — | — |
| — **Block 5** — |||||||
| conv08 | Conv2D | 96→96 | 3×3 | 1 | 1 | 30×64 | 82,944 | 81.0 |
| conv09 | Conv2D | 96→96 | 3×3 | 1 | 1 | 30×64 | 82,944 | 81.0 |
| pool5 | MaxPool 2×2 s2 | 96 | 2×2 | 2 | 0 | 15×32 | — | — |

> BN 已在量化前融合进卷积（权重+偏置），上表即融合后的最终结构；
> 推理数据流：`x_i8·w_i8 → INT32 累加 → requant → INT8`，逐层公式见第 5 节。

## 4. PG2K100 片上 RAM 预算（BRAM 共 144×36Kb = 632KB，另分布式 RAM 99KB）

| 实现方案 | 权重 | 偏置 | 行缓冲 | +余量 | **合计 / 632KB** | 结论 |
|---|---|---|---|---|---|---|
| **逐层串行（推荐起步）** | 367.2 KB | 2.4 KB | 48.0 KB（单层峰值） | 20 KB | **437.5 KB** | ✓ |
| **块内双卷积流水（推荐）** | 367.2 KB | 2.4 KB | 72.0 KB（块峰值） | 20 KB | **461.5 KB** | ✓ |
| 全网络流水（3 行缓冲） | 367.2 KB | 2.4 KB | 297.0 KB（所有层同时） | 20 KB | **686.5 KB** | ✗ 超出，改 2 行=587.5KB ✓ |

> 输入帧（1.4MB）与各 block 间特征图（1~2MB）不入 BRAM：整网按行流式处理，
> 帧数据从 DDR3 经 AXI 流入、GAP 前的 feature map 流回 DDR。权重全部常驻片上。
> 单层最大权重 81 KB
>（conv07），可整层装入单 bank 组。

## 5. 候选配比对比（config.py 一行切换，改后需重新训练+量化）

| MODEL_PROFILE | INT8 卷积权重 | 最大单层 | MACs/帧 | 632KB 结论 |
|---|---|---|---|---|
| [16/32/48/96/96]  ← 最保守 | 333 KB | 81 KB | 5.4 G | ✓ 片上驻留 |
| [16/32/64/96/96]  ← **默认** | 367 KB | 81 KB | 6.1 G | ✓ 片上驻留 |
| [16/32/64/128/128]  ← 容量最大 | 574 KB | 144 KB | 7.0 G | ✗ 需 DDR3 权重流送 |
| [32/64/128/256/512]  ← 豆包初版 | 4600 KB | 2304 KB | 32.1 G | ✗ 需 DDR3 权重流送 |

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
| `quant_params.json` / `quant_params_table.md` | 每层 scale/zp/偏置（json + md） | FPGA |
| `weights_int8/*.npy` | 每层 INT8 权重 + INT32 偏置 | FPGA |
| `preprocess_spec.json` | BILINEAR→1024×480→/255 规格与输入 scale | FPGA |
| `fpga_architecture_spec.json` | 本文档的机器可读版 + 预算表 | FPGA |
| `test_vectors/` | 逐层 FP32/INT8 测试向量 + manifest | FPGA |
| `model_int8.onnx` | QDQ 全模型（onnxruntime 可直接跑, 精度对照用） | ARM |
| `head_int8.onnx` | 分类头单独 INT8（配 FPGA feature map） | ARM |
