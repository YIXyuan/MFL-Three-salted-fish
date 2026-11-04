# MFL_ARM —— ARM 前半 + 后半 融合包

> 范围: MFL 边缘监测系统 PU(A53) 侧全部 ARM 软件 = **前半（图片→FPGA）+ 后半（分类头→上报）**
> 位流: v3.2（VERSION=0x20261018）｜ 邮箱契约: 见03_docs\《FPGA组对接地址表.md》

## 0. 全链数据流（两半如何协作）

```
SD 图片 (/root/sd_in/*.jpg)
  │ ① 前半 app_arm: stb 解码 → >>1 量化 → CHW → 写 IN_BUF → v3.2 邮箱 START
  ▼
FPGA 位流 (10 层卷积+ReLU+Pool → int8[96][15][32] @0.1372978389, OUT@0x470000)
  │ ② 前半 app_arm: 轮询 STATUS done → 读 OUT
  ▼
③ 后半分类头 head.c: GAP → FC1(96→256) → ReLU → FC2(256→3) → softmax
  │ ④ 前半 app_arm: severity → POST /api/detections
  ▼
Web 大屏 (mflweb, :8080): 状态/趋势/告警
```

## 1. 目录结构（86 个文件）

```
MFL_ARM/
├── 01_frontend/               ★ ARM 前半
│   ├── 01_arm_source/         完整源码: main.c / preprocess.c·h / fpga_if.c·h / fpga_regs.h /
│   │   │                      report.c·h / head.c·h(前半集成版) / head_params.h·json / stb_image.h /
│   │   │                      Makefile
│   │   ├── fpga_mem/          FPGA 权重与配置: weights·bias·mc·layer_config·boundary.mem
│   │   ├── weights/           mfl_head.bin（app_arm 加载的头权重, md5 e7c3b41c）
│   │   ├── tests/             test_head / test_preprocess + 测试图与期望值
│   │   └── tools/             gen_fpga_mem / gen_head_assets / head_ref_check（生成与对拍脚本）
│   ├── 02_board_binaries/     板端静态二进制: app_arm（主程序, 内嵌分类头）/ pretest_arm /
│   │                          headtest_arm / mfl_fill·mfl_dump·mfl_peek·mfl_reg_test（寄存器工具）
│   └── 03_assets/             golden 特征图: golden_conv09_prepool_0x2FF.bin（跳池化 30×64）/
│                              golden_feat_full_0xFF.bin（全链 15×32）/ preprocess_spec.json
├── 02_backend/                ★ ARM 后半 = 分类头
│   ├── 01_models/             model_int8.onnx（参数权威, md5 ab31e3fd）/ model_fp32_fused.onnx /
│   │                          head_fp32.onnx
│   ├── 02_parameters/         quant_params.json（量化参数）/ quantization_report.json /
│   │                          head_weights.bin（本方工具加载格式）/ w1·b1·w2·b2 原始层参数
│   ├── 03_code/
│   │   ├── c/                 src/(head·head_service·fpga_if·quant_params.h) app/(head_cli·dump_out)
│   │   │                      test/(test_head·test_service) Makefile build.bat（源码已去注释）
│   │   └── python/            参数导出与对拍: gen_c_params（6 重交叉验证）/ gen_test_vectors /
│   │                          gen_batch20 / prep_pick100 / compare_* / replica_qdq / inspect_onnx /
│   │                          mock_web（PC 端上报联调桩）
│   ├── 04_test_data/e2e_100/  100 张实拍全链实测参考: pick100_ref.json（选图与参考结果）/
│   │                          state_100.json（上报后 Web 状态快照）
│   └── 05_build/              linux-arm64/(test_head·test_head_qdq·head_cli·test_service·dump_out)
│                              windows/(4 个 PC exe: test_head·test_head_qdq·head_cli·test_service)
├── 03_docs/                   ★ ARM 文档
│   └── FPGA组对接地址表.md     v3.2 DDR 轮询邮箱契约（寄存器/地址/状态机/时序）
└── README.md
```

## 2. 两半的分工与对接

|      | 前半（01_frontend）                                      | 后半（02_backend）                                          |
| ---- | ---------------------------------------------------- | ------------------------------------------------------- |
| 职责   | 图片解码/量化、邮箱驱动、帧调度、结果上报                                | 分类头数学（GAP/FC/softmax）+ 参数与验证                            |
| 核心交付 | app_arm（板端二进制）、main.c/preprocess/fpga_if 源码          | head.c（板端内嵌于 app_arm）、head_cli/test_head（独立工具）、参数与向量    |
| 权重文件 | `01_arm_source/weights/mfl_head.bin`（app_arm 加载格式）   | `02_parameters/head_weights.bin`（本方工具加载格式） |
| 对拍锚点 | `04_assets/golden_*.bin` | `04_test_data/e2e_100/pick100_ref.json` |

> 两边各有一份“头权重”文件：`mfl_head.bin`（前半打包格式）与 `head_weights.bin`
> （后半打包格式），**同一套 D 档模型参数**、不同容器，分别服务 app_arm 与本方工具，勿混用。

## 3. 关键事实

1. 特征图 `int8[96][15][32]`（conv09+ReLU+Pool 全在 FPGA 内），scale=0.1372978389；30×64 为跳池化模式（LAYER=0x2FF）。
2. 类别 0/1/2 = 无腐蚀/轻度/重度 = Web severity。
3. 邮箱 0x301000 为 DDR 轮询邮箱；VERSION 在首帧 START 后才写入（0x20261018）。
4. 实测性能：100 张全流程 593.2s（5.93s/帧），瓶颈在 FPGA（5.77s/帧）。
5. 参数权威是 `model_int8.onnx`；`head_int8.onnx` 因中间 requant scale 过期不可用。
6. 源码中的板卡/VM 密码占位为 `<BOARD_PWD>`/`<VM_PWD>`。

## 4. 快速上板

```bash
# 前半全流程（图片放 /root/sd_in 后执行）
cd /root && ./app_arm --health-wait 0 --csv-out /tmp/e2e.csv --fail-csv /tmp/e2e_fail.csv

# 后半单帧/自测（/root/mfl_head）
./bin/test_head weights/head_weights.bin test_vectors
./bin/head_cli -w weights/head_weights.bin -i <input_int8.bin> --fpga --layer 0xFF --dump out.bin

# Web
wget -qO- http://127.0.0.1:8080/api/state
```

## 5. 重新生成 FPGA 权重 mem（可选）

由模型侧操作：
`tools/gen_fpga_mem.py` 从 `weights_int8/conv*_int8.npy` 生成 `fpga_mem/weights.mem`。
包内未携带 npy 中间产物，需要再生时先从 `02_backend/01_models/model_int8.onnx`
导出各层 int8 权重/偏置为 npy（`03_code/python/gen_c_params.py` 有现成的 ONNX 初始化器读取逻辑），
再运行：

```bash
python3 tools/gen_fpga_mem.py <包含 weights_int8 的目录>
```
