# MFL 2D-CNN 管道腐蚀识别训练管线 (MFL-2DCNN)

针对紫光同创 PG2K100 (Kosmo-2 SoC: 双核 A53 + FPGA 阵列) 边缘监测系统的 MFL 伪彩图
腐蚀识别方案：**图像级三分类（正常 / 轻度腐蚀 / 严重腐蚀）**，FP32 本地训练 →
INT8 静态量化 → ONNX + 逐层定点参数交付 FPGA/ARM 组。

```
原始 MFL 伪彩图 5000x2400 ──BILINEAR缩放──> 1024x480 ──/255──> 2D-CNN
                                                              │
             ┌────────────────────────────────────────────────┤
             ▼ FPGA(PA): conv00..conv09 (INT8, 权重片上驻留)    ▼ ARM(PU): GAP + FC(96→256→3)
             BRAM 预算: 权重 ~367KB + 行缓冲 < 632KB           head_int8.onnx (onnxruntime)
```

**当前配置（DATA_LAYOUT="full"）**：数据与标签来源于"https://hf-mirror.com/datasets/PipeMFL/PipeMFL-240K/tree/main"。

## 结果摘要

| 项 | 数值 |
|---|---|
| 任务 | PipeMFL-240K 12 类检测标注 → 图像级三分类（normal / light / severe，按 MTL 金属损失面积比 0.1% 阈值） |
| 模型 | VGG 风格 [16,32,64,96,96]，**402,803 参数**；INT8 权重 **367KB**（632KB 片上 BRAM 预算内），~6 GMAC/帧 |
| FP32 精度（test 48,064 张） | acc **72.9%** / macro_f1 **0.599** / severe_recall **78.4%**（severe 类召回优先） |
| INT8 量化（Entropy 校准 + 2048 样本） | test-3000 argmax 一致率 **97.8%**，INT8 acc 较 FP32 **+0.1pt**（无掉点） |
| 定点链验证 | fpga_sim 端到端 probs vs ORT-int8 全模型 **max\|Δ\|=0.0000**；板上实测 feat vs 定点仿真**位级零差** |
| 交付物 | model_int8.onnx + 逐层 scale/偏置 + 权重 .mem 五件套 + 逐层测试向量（`output/quant_export/`） |

逐层 INT8 对拍验收标准：FPGA/ARM 实现输出与 `test_vectors/*_out_int8.npy` 逐元素 |diff| ≤ 1。

## 0. 环境安装

```bash
pip install -r requirements.txt
python -m pip uninstall -y torch
python -m pip install torch --index-url https://download.pytorch.org/whl/cu128
python check_env.py     # 确认打印 "GPU 就绪", 并核对数据/分卷/缓存状态
```

## 1. 全量训练操作顺序

```bash
# ① 流式预处理(不解压落地, 分卷保持原样; 断点续跑: 重跑同一命令)
python preprocess_tar.py --split-name train    # 11 卷 328GiB -> cache\train-cache, 约 1.0 小时
python preprocess_tar.py --split-name val      #  4 卷 110GiB -> cache\val-cache,   约 0.4 小时
python preprocess_tar.py --split-name test     #  4 卷 109GiB -> cache\test-cache,  约 0.4 小时

# ② 训练(只读缓存, 与预处理完全分离; 断点续训 --resume)
python train.py                                # 全量约 15~25 分钟/epoch × 20
# 冒烟: python train.py --max-samples 512 --epochs 2

# ③ 评估(官方 val 48,064 张, 有 val_coco.json 完整可评)
python evaluate.py

# ④ 量化与交付物
python quantize_export.py
python compare_int8.py            # FP32 vs INT8 真实掉点测量(默认 val/test 3000 张, 约15分钟)
python compare_int8.py --images-dir <目录> --glob "P000[12]_*.jpg" --n 0
                                  # 纯一致率模式(无标注也可跑), --glob 可按点位/桶过滤
python export_test_vectors.py
python export_structure.py        # 重新生成 MODEL_STRUCTURE.md(配比/开关变化后)
```

产物都在 `output/`：`MODEL_STRUCTURE.md`（结构表格）、`models/`、`logs/`（训练曲线 CSV）、
`eval_results/`、`quant_export/`（量化交付物）、`test_vectors/`。
**板端链路开发（FPGA+ARM+Web 联合）的系统级说明见仓库根目录 `README.md`**——从 SD 卡图像到
大屏显示的完整运行流程、设计理念与设计流程、接口契约（DDR 共享窗/邮箱寄存器/LAYER 调试位）、
逐层对拍方法与常见坑；**开发板实测硬件档案见 `Global_Docs/BOARD_AUDIT.md`**（给其他组员建立先提知识用）；
`tools/gen_fpga_mem.py` 由 quant_params.json + weights_int8 生成 FPGA 权重/参数 .mem 五件套
（weights/bias/mc/boundary/layer_config）；
`tools/fpga_sim.py` 为 F=24 定点全链仿真器（L1 位级锚点，round/floor 双模式，
`--dump-layers` 导出逐层 pre-ReLU pre-Pool 张量，`--ref-dir` 对拍 ORT 参考）；
`tools/selfcheck_int8_chain.py` / `chain_check_dsh.py` 为逐层向量自检（int8 链复算）；
`board_probe.py` 为板端只读 SSH 探针（复核硬件状态）。

## 2. 数据与缓存说明

- **分卷**：train/val/test 的 `*_part_NN` 无后缀文件是未压缩 tar 按字节切开的分卷
  （首卷有 ustar 头、末卷有结束零块），脚本默认按文件名序拼接成一条流读取；
  末卷内附带的 labels(txt)/coco(json) 会被图像扩展名过滤自动屏蔽。
- **缓存**：JPEG q95 实测约 291KB/张，train(144,192)≈42GB + val(48,064)≈14GB ≈ **55GB**，
  训练、评估、量化校准、FPGA 参考读的都是同一份缓存，口径天然一致。
- **预处理即 FPGA 交付**：`cache/` 下的 1024×480 图像就是 FPGA 端推理时的前端产物规格
  （BILINEAR + /255），`preprocess_spec.json` 是对应的机器可读规格。
- **test 集现状**：4 个分卷已完整下载（尾部 tar 结束块齐全）并完成流式预处理
  （test-cache 48,064 张），test_coco.json（48,064 图）在 MFL_datafile 下。evaluate 默认
  评估 test，val 可用 `--split val`；`cache\labels_test.json` 标签缓存会在
  首次评估时自动生成。compare_int8.py 的 `--split auto` 也优先使用 test。
- **磁盘占用**：三套缓存合计约 69GB（train 42 + val 14 + test 14），G 盘空闲约 190GB，健康。

## 3. 标签口径（图像级三分类）

数据集原始标注是 12 类检测框（YOLO/COCO）。腐蚀识别按 `config.py` 规则换算：

| 标签 | 规则（默认 `AREA_RATIO_MODE="max"`） |
|---|---|
| normal (0) | 图中无腐蚀类框（`CORROSION_CATEGORY_NAMES=["MTL"]`） |
| light (1) | 腐蚀框最大面积占整图比例 < 0.001 |
| severe (2) | 最大占比 >= 0.001（≈原图 110×110 像素缺陷） |

全量分布（COCO 统计核实）：train 108,595 / 26,641 / 8,956（75.3% / 18.5% / 6.2%），
val 36,207 / 8,895 / 2,962。**改阈值只需删除 `output/cache/labels_*.json` 重跑训练**，无需重新预处理。

**可选腐蚀类型双头**（`ENABLE_TYPE_HEAD=True`）：ARM 分类头额外输出 MTL(金属损失)/
CRC(复合修复腐蚀) 存在性（BCE 训练，正类权重自动按逆频率），FPGA 侧结构完全不变。
默认关闭——先做基础三分类上板，成功后再增量开启（train 含 MTL 图 35,597 张、CRC 图 1,280 张）。

## 4. 模型规模（与 FPGA 片上 RAM 的匹配）

PG2K100 片上 BRAM = 144×36Kb = **5.06Mb ≈ 632KB**（另分布式 RAM 99KB）。
候选配比在 config.py 一行切换（`MODEL_PROFILE`），INT8 量化后对比：

| 配比 | INT8 卷积权重 | 最大单层 | 计算量 | 632KB 片上结论 |
|---|---|---|---|---|
| [16,32,48,96,96] | ~333KB | 81KB | ~5.4 GMAC | ✓ 最保守 |
| **[16,32,64,96,96]（默认）** | **~367KB** | **81KB** | **~6 GMAC** | ✓ 串行/块内流水均驻留 |
| [16,32,64,128,128] | ~574KB | 144KB | ~7 GMAC | ⚠ 需 FPGA 组复核缓冲 |
| [32,64,128,256,512]（豆包初版） | ~4.4MB | 2.25MB | ~320 GMAC | ✗ 需 DDR3 权重流送 |

> 注意单位：FPGA BRAM 是 5.06 **Mb**（兆位），不是 5MB。上表体积均为 INT8 交付口径；
> FP32 训练模型（默认配比约 1.4MB）只留在 GPU 侧作精度基准，不上板。
> 逐层结构与三档片上 RAM 预算详见 `python export_structure.py` 生成的 `output/MODEL_STRUCTURE.md`。

## 5. 给 FPGA / ARM 组的交付物（output/quant_export/）

| 文件 | 用途 |
|---|---|
| `model_int8.onnx` | QDQ 静态量化全模型（权重 per-channel s8、激活 per-tensor s8 对称），ARM 可直接 onnxruntime 部署 |
| `head_int8.onnx` | ARM 侧分类头（GAP+FC），配合 FPGA 输出的 feature map 使用 |
| `quant_params.json` / `quant_params_table.md` | 每层 scale/zp/偏置（json 机器读，md 表格人读） |
| `weights_int8/*.npy` | 每层 INT8 权重与 int32 偏置数组，用于 BRAM 初始化 |
| `preprocess_spec.json` | 预处理规格（BILINEAR→1024×480→/255），FPGA 前端必须严格一致 |
| `fpga_architecture_spec.json` | v1.3 结构规范：逐层参数、片上 RAM 预算表、requant 公式、DDR 流送备选 |
| `quantization_report.json` | FP32 vs INT8 逐样本一致性/精度对比 |

**定点数据流约定**：行缓冲 3×3 卷积 → INT32 累加 →
`y_f = acc32 × act_in_scale × w_scale[c]` → `y_i8 = clamp(round(y_f / act_out_scale), -128, 127)`。

**验收标准**：`test_vectors/` 中每层 FPGA 实现输出与 `*_out_int8.npy` 逐元素 |diff| ≤ 1。

## 6. FAQ

- **训练只走了 CPU**：torch 装成 CPU 轮子了（`torch.__version__` 带 `+cpu`）。按第 0 节重装；
  本管线检测不到 GPU 会直接报错并给修复指引，不会静默用 CPU。
- **显存不足 (OOM)**：config 里 `BATCH_SIZE` 32→16；再不行关 `CHANNELS_LAST`。
- **训练报"图像目录不存在"**：缓存没生成，先跑 `preprocess_tar.py --split-name train`（可断点续传）。
- **改了 SEVERE_AREA_RATIO / 双头开关不生效**：删除 `output/cache/labels_*.json`
  （标签缓存签名含这些配置，正常会自动失效重建；手动删最保险）。
- **量化时报错找不到 `*-inferred.onnx`**：onnxruntime 的 C++ 形状推断在 Windows
  **非 ASCII 路径**（含中文）下会静默失败。本脚本已内置规避（量化在 ASCII 临时目录执行后拷回）。
- **换模型配比**：config.py `MODEL_PROFILE` 一行；换完须重新训练 + 重新量化，交付物自动重生成。

## 7. 仓库结构

```
MFL-2DCNN/
├── README.md / requirements.txt
├── config.py                  # 全局配置（数据路径 / 模型超参 / 量化常数）
├── check_env.py               # 环境自检（训练前先跑）
├── preprocess_tar.py          # 数据预处理（分卷流式 → 缓存，断点续跑）
├── dataset.py / model.py      # 数据集（COCO+YOLO 标签→三分类）与 MFLCNN 模型定义
├── train.py / evaluate.py     # 训练（断点续训）与测试集评估
├── quantize_export.py         # INT8 PTQ（Entropy 校准）+ 交付物导出
├── compare_int8.py            # FP32 vs INT8 精度/一致率对比
├── export_test_vectors.py     # 逐层测试向量导出（FPGA 对拍用，工具见 tools/）
├── export_structure.py / gen_head_assets.py   # 结构文档 / ARM 头资产生成
├── board_probe.py             # 板端只读 SSH 探针（密码不入库，运行时传入）
├── tools/
│   ├── fpga_sim.py            # F=24 定点全链仿真器（L1 位级锚点，round/floor 双模式）
│   ├── gen_fpga_mem.py        # 权重/参数 .mem 五件套生成器（消费 quant_params.json）
│   ├── PyTools_Readme.md      # 全部 Python 脚本用途汇总
│   ├── selfcheck_int8_chain.py / chain_check_dsh.py   # 逐层向量自检
└── output/
    ├── models/best_model.pt           # 训练权重（epoch16, score 0.7599）
    ├── quant_export/                  # INT8 交付物：model_int8.onnx、quant_params.json、
    │                                  #   weights_int8/*.npy、fpga_architecture_spec.json 等
    ├── eval_results/                  # FP32 vs INT8 对比报告
    ├── MODEL_STRUCTURE.md             # 结构表格
    └── test_vectors/                  # manifest + README（重导命令见 §1④）
```
