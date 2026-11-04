# MFL 管道腐蚀边缘监测系统（MFL Pipeline）

面向**管道漏磁（MFL, Magnetic Flux Leakage）内检测图像**的腐蚀严重度识别系统。整条链路跑在**一块国产异构 SoC 开发板**（紫光同创 PG2K100 / Kosmo2-MES2K100：FPGA 阵列 PA + 双核 Cortex-A53 PU）上，全程离线：从 SD 卡读图 → 板端推理 → 本机 Web 大屏可视化，不需要任何云端算力。

```
SD 卡图像 ──> ARM 预处理 ──> FPGA 10 层 INT8 卷积 ──> ARM 分类头 ──> Web 大屏
 (1024×480)    (解码/量化)     (权重 367 KB 全片上)     (GAP+FC+softmax)   (热力图/告警/趋势)
```

| 指标 | 值 |
|---|---|
| 单帧端到端 | **5.93 s**（FPGA 卷积 5.76 s + 前后处理约 0.17 s） |
| 批量稳定性 | 114/114 帧全部成功，无丢帧、无超时 |
| 三分类精度 | FP32 测试集 acc 72.9%，INT8 量化后无掉点（argmax 一致率 97.8%） |
| 全链一致性 | 板上特征图与定点参考逐字节相同；端到端 99/100 与 PC 参考一致（唯一分歧为决策边界帧） |
| FPGA 资源 | LUT 25,504（47.6%）、FF 22,390、APM 68、**DRM 138.5/144（96.2%）** |
| 时序签核 | 50 MHz，WNS **+3.429 ns**，0 条失败路径，Fmax 60.35 MHz |
| 板端形态 | 全 C/Go 静态二进制，板上无 Python、无 pip、无编译环境 |

---

## 1. 系统组成

| 子项目 | 职责 | 语言/工具 | 产物 |
|---|---|---|---|
| [`MFL_2DCNN`](MFL_2DCNN/README.md) | 数据集预处理、模型训练、INT8 量化、交付物导出 | Python + PyTorch + onnxruntime | `model_int8.onnx`、`quant_params.json`、`weights_int8/*.npy`、逐层测试向量 |
| [`MFL_FPGA`](MFL_FPGA/MFL_FPGA/README.md) | 10 层 INT8 卷积特征提取引擎（PA 侧） | Verilog + PDS 2025.2 | `AXI_wrapper.sbit` 位流 + `BOOT_PG.bin` 启动镜像 |
| [`MFL_ARM`](MFL_ARM/README.md) | 前半（取图/量化/邮箱驱动/上报）+ 后半（分类头 GAP+FC+softmax） | C（aarch64 静态） | `app_arm` 板端主程序 |
| [`MFL_Web`](MFL_Web/README.md) | 管网大屏：实时热力图、告警、趋势、历史回看 | Go（纯标准库）/ HTML+JS | `mflweb-linux-arm64` 后端 + 前端页面 |
| [`Global_Docs`](Global_Docs/BOARD_AUDIT.md) | 板级硬件核查档案（实测经验底稿） | Markdown | `BOARD_AUDIT.md` |

数据/权重只在模型侧产生一次，其余三方都只消费它——**没有任何一处手抄量化参数**。

```
纯净项目包/                      322 files / 54.8 MB
├── README.md                         本文件（全局说明）
├── MFL_2DCNN/    54 files   4.3 MB   训练与量化（PC/GPU）
├── MFL_FPGA/    143 files  22.0 MB   位流工程、RTL、仿真、板端工具
├── MFL_ARM/      86 files  15.1 MB   C 源码、板端二进制、参数、测试向量
├── MFL_Web/      35 files  13.3 MB   Go 后端、前端、拓扑数据
└── Global_Docs/   1 files            板级核查档案
```

---

## 2. 数据流

```
① ARM  app_arm：从 /root/sd_in 取一张 1024×480 JPEG，stb_image 解码 → uint8 RGB(HWC)
② ARM  app_arm：int8 量化（等价于 v>>1，scale=1/127, zp=0）+ HWC→CHW 重排
                → 得到 int8[3][480][1024]（1.4 MB），写入 DDR 共享窗 IN 缓冲 0x302000
③ ARM  app_arm：写邮箱 IN_ADDR / OUT_ADDR / LAYER=0xFF，然后写 CTRL=1 启动
④ FPGA M9：轮询邮箱 → AXI 主从共享窗取输入 → M3 行缓冲 3×3 滑窗
                → M4 乘加阵列（96 个 8×8 乘法器，int8×int8→int32）
                → M5 再量化 + ReLU +（块末 2×2 MaxPool）
                → 逐层推进 conv00…conv09，中间平面在 DDR 与片上缓冲间往返
⑤ FPGA M9：结果 int8[96][15][32]（46,080 B）写回 OUT 缓冲 0x470000，STATUS 置 done
⑥ ARM  app_arm：轮询到 done → 读 46,080 B 特征图
⑦ ARM  head.c：GAP（96 通道各自累加 480 项）→ FC1 96→256 → ReLU → FC2 256→3 → softmax
⑧ ARM  report.c：POST {"point_id":"P0280","severity":2} 到 127.0.0.1:8080/api/detections
                失败时落 report_failed.csv 兜底，不阻塞后续帧
⑨ Web  mflweb：更新点位状态 → SSE 推送大屏 → 触发/推进告警 → 归档图像到 data/captures
```

**ARM 与 FPGA 只通过两样东西耦合**：64 MiB DDR 共享窗（`/dev/uio0`，物理 0x300000 起）里的数据缓冲，以及窗内偏移 0x1000 处的 6 个 32 位邮箱寄存器。没有中断（设备树节点未接中断线，v1 用 1 ms 轮询）、没有自写内核驱动、没有运行时加载位流。

---

## 3. 设计理念

这套系统的每一个设计选择都服从四件事：**指标可复现、链路可观测、参数单一来源、硬件留给算力**。

1. **先有可信参考，再谈硬件。** 模型侧在 PC 上把整条定点链（量化 → 逐层 requant → GAP/FC）用 numpy 重算一遍，与训练框架输出对齐到**位级**，才允许 RTL/ARM 动手。所有后续对拍都锚在这份参考上——这也是最后能做到"板上特征图与仿真逐字节相同"的前提。
2. **契约先行，数字禁止手抄。** `quant_params.json` 是量化参数的唯一来源：FPGA 侧的 `weights/bias/mc/layer_cfg/boundary` 五件套 `.mem`、ARM 侧的 `quant_params.h`，全部由脚本生成；改模型只需重跑导出，不改一行硬件代码。
3. **权重放在最贵的地方，数据放在最便宜的地方。** 默认配比 INT8 卷积权重 **367 KB**，全部驻留片上 BRAM（632 KB 预算内），因此推理不需要 DDR 权重流送——DDR 只承担特征图/中间平面。这也是模型配比在 `[16,32,64,96,96]` 定稿的原因：换更大配比（574 KB / 4.4 MB）就会打破这条前提。
4. **每一步都要能被"停住看"。** 邮箱里留了 `LAYER` 调试寄存器：`bit[7:0]` 指定停止层，`bit8` 跳过 ReLU，`bit9` 跳过池化。于是任意一层都能被单独导出（`mfl_dump` 工具，读 `/dev/uio0`）并对拍到字节级；不需要改位流、不需要重新综合。这条能力直接决定了后期定位问题的速度。
5. **异构分工按"搬运成本"切，不按"算法归属"切。** 算力密集的 10 层卷积在 PA；控制/字符密集的解码、量化、分类头、HTTP 上报在 PU。分类头之所以放在 ARM，是因为 GAP 之后只剩 2.5 万次乘加（<1 ms），而把它硬化到 FPGA 只会增加一次 DDR 往返和一堆定点对齐工作。
6. **先简单正确，再并行。** v1 采用"逐层串行 + 层间经 DDR 中转"，牺牲了理论吞吐（理想拍序 4.31 s vs 实测 5.76 s，MAC 利用率约 21%），换来的是每层都能独立对拍、错误可定位。并行度（多像素列、块内流水）留给后续版本，因为**当前瓶颈是拍序与 DDR 往返，不是乘法器数量**。

---

## 4. 运行流程

### 4.1 上电与启动链

```
SD 卡 BOOT 分区 (FAT32)                    SD 卡 ROOTFS 分区 (ext4)
├── BOOT_PG.bin  ← 启动镜像（FSBL + 位流 + u-boot + kernel + dtb + bl31）
└── ...                                      /root/mflweb     Web 后端与前端
                                             /root/sd_in      待检图像队列
                                             /root/app_arm    推理主程序
```

1. 上电后 FSBL 按 icf 分区表把各段搬到 DDR：**PS 侧分区顺序固定**，位流必须放**第 2 分区**（放错会覆盖 BL31/u-boot 的暂存区，表现为读卡报错或 u-boot 卡死）。
2. FSBL 跳转 bl31 → u-boot → 内核（Linux 5.10 / Buildroot 2022.08.1 / glibc 2.25）→ 挂载 rootfs。
3. 位流此时已由 FSBL 写入 PA 配置区，FPGA 侧处于"上电即就绪、等待邮箱"状态。
4. Web 后端由 `/etc/init.d/S99mflweb` 拉起（`--offline-minutes 30`），监听 0.0.0.0:8080。
5. 推理程序按需启动（见 4.3），它只依赖 `/dev/uio0` 与本地回环：

```bash
cd /root && ./app_arm \
  --reg-base 0x301000 \
  --watch-dir /root/sd_in \
  --head-weights weights/mfl_head.bin \
  --backend 127.0.0.1:8080 \
  --captures-dir /root/mflweb/data/captures \
  --health-wait 0 \
  --csv-out /tmp/e2e.csv
```

### 4.2 单帧时序

| 阶段 | 承担 | 耗时 | 说明 |
|---|---|---|---|
| 解码 + 量化 + 重排 | ARM | ~10 ms | stb_image 解码 + `>>1` + HWC→CHW；**板上不做缩放** |
| 10 层卷积 + ReLU + Pool | FPGA | 5,760 ms | 287,850,000 个忙周期 @50 MHz |
| 读回 + 分类头 + softmax | ARM | <1 ms | 46,080 B 读 + 2.5 万次乘加 |
| 上报 + 归档 | ARM/Web | ~few ms | 裸 socket POST，Web 侧落盘 |
| **合计** | | **~5.93 s/帧** | 队列作业场景，满足巡检节奏 |

> 说明：早期设计文档里凭算力估过 `0.2~0.5 s/帧（2~3 FPS）`。那个数字假设 256 个乘加器打满、层间无 DDR 往返；实测 5.76 s 的真实原因是拍序（每像素 9 拍乘加 + 4 拍再量化 + 池化）与逐层 DDR 中转。**结论：算力不是瓶颈，调度和访存才是**——这正是后续优化（多列并行、块内流水）的切入点。

### 4.3 三种运行模式

| 模式 | 用途 | 关键参数 |
|---|---|---|
| 实模式（默认） | 真机全链：读图 → FPGA → 头 → 上报 | `--reg-base 0x301000 --watch-dir /root/sd_in` |
| 对照模式 | 有 `--plan manifest.csv` 时叠加点位/期望结果，逐帧写 CSV（`new_name,plan,pred,p0,p1,p2,match`） | `--plan /root/manifest.csv --csv-out /tmp/e2e.csv` |
| 回放/stub 模式 | 无 fabric 时用 `--stub-vectors` 吃 conv09 向量；`--mode replay` 按节奏重发历史结果 | `--stub-vectors ... / --mode replay --interval-ms 100` |

图像命名要带点位号（`P0280_002.jpg` → 点位 `P0280`、第 2 轮），Web 侧据此定位到管网节点；尺寸必须**严格 1024×480**（PC 端 `preprocess_tar.py` 的产物规格），否则该帧被拒绝并记录原因。`./app_arm --help` 可看全部参数，另有两个常用开关：`--arm-pool`（池化改在 ARM 侧做，用于对拍 FPGA 池化）与 `--max-sweeps N`（`feed_order` 轮数，0=不限）。

---

## 5. 设计流程

### 5.1 主流程

```
① 数据与标签口径          PipeMFL-240K（12 类检测框） → 图像级三分类
                          normal / light / severe（MTL 面积占比 0.1% 阈值）
                          train 144,192 · val 48,064 · test 48,064
        │
② 训练（FP32）            VGG 风格 [16,32,64,96,96]，402,803 参数，~6 GMAC/帧
        │                 acc 72.9% / macro-F1 0.599 / severe 召回 78.4%
        ▼
③ 量化（INT8 PTQ）        Entropy 校准 + 2048 样本；权重 per-channel s8、激活 per-tensor s8 对称
        │                 argmax 一致率 97.8%，无掉点
        ▼
④ 交付物导出              quant_params.json（每层 scale/zp/bias）＋ weights_int8/*.npy
        │                 ＋ 逐层测试向量（FP32 与 INT8 双口径）＋ preprocess_spec.json
        ▼
⑤ PC 定点链复算           自写定点仿真器（F=24 乘数定点）跑完 10 层，与量化模型对拍到位级
        │                 ← 这是全项目最重要的一道闸：参考错了，后面全错
        ▼
⑥ FPGA 实现（PA）         逐模块：DMA 读/写主 → 行缓冲 → 乘加阵列 → 再量化/池化 → 单层引擎
        │                 → 参数仓库 → 层序控制 → 邮箱适配；每模块先单元仿真对拍
        ▼
⑦ ARM 实现（PU）          preprocess（解码/量化/重排）→ fpga_if（UIO 映射/邮箱/超时）
        │                 → head（GAP/FC/softmax）→ report（HTTP 上报/兜底 CSV）
        ▼
⑧ 逐层上板对拍            LAYER 停层导出，逐层比字节：|Δ|≤1（实测十层全部 0 差）
        ▼
⑨ 全链验收                特征图 vs 金标准（位级）；端到端 vs PC 参考（99/100）
        ▼
⑩ 系统集成                Web 上位机联调 → 批量连跑（114 帧）→ 现场节奏（点位轮次）
```

### 5.2 每个阶段"过关"的判据

| 阶段 | 判据 | 本轮实测结果 |
|---|---|---|
| 量化 | INT8 与 FP32 的 argmax 一致率 ≥95% | 97.8%，acc 无掉点 |
| 定点参考 | 自写定点链 vs 量化 ONNX，逐层逐元素 \|Δ\| ≤ 1 | F=24 口径下全 10 层 **0 差** |
| FPGA 单层 | 每层输出 vs `*_out_int8.npy`，\|Δ\| ≤ 1 | 逐层全部 0 差 |
| 全链特征 | 板上 46,080 B vs 金标准，逐字节比较 | 位级相同（md5 一致） |
| 端到端 | 三分类结果 vs PC 参考（100 帧） | 99/100（唯一分歧为并列/边界帧） |
| 系统 | 连续批量运行无丢帧、Web 状态一致 | 114/114 帧，点位回显全对 |

### 5.3 验证方法学

- **可停**：`LAYER=0x00..0x09` 停在某一层；`0xFF` 跑全链。
- **可切口径**：`bit8=1` 跳过 ReLU、`bit9=1` 跳过池化——因为训练侧 golden 是 **pre-ReLU / pre-Pool** 口径，不切就只能对"后处理过"的数据，误差来源说不清。
- **可导出**：`mfl_dump`（`/dev/uio0` mmap + 邮箱启动 + 导出任意层输出）把中间平面按原始字节 dump 回 PC，再用 Python 逐通道/逐段/逐元素比对。
- **可复跑**：同一参数两次运行的 dump 逐字节相同（已实测），说明缺陷不来自时序竞争——这一条能立刻把"偶发 vs 结构性"分开。
- **导出地址不能和输入平面重叠**：停层导出时输出写到 `out_addr`，若与输入/中间平面（`0x500000` / `0xD00000`）重叠，后段行会在被计算之前就被自己的输出覆盖，表现为"尾部几十行全错"的假缺陷。工具已加重叠守卫。

---

## 6. 关键接口契约

### 6.1 DDR 共享窗布局（物理地址，窗基 0x300000 / 64 MiB，`/dev/uio0`）

| 区域 | 物理地址 | 大小 | 用途 |
|---|---|---|---|
| 邮箱（6×32 bit） | `0x301000` | 64 B | ARM↔FPGA 控制/状态 |
| IN slot0 数据 | `0x302000` | 1.4 MB（预留 2 MB） | int8[3][480][1024] 输入张量 |
| final OUT | `0x470000` | 46,080 B | int8[96][15][32] 特征图 |
| scratch A（偶层写） | `0x500000` | 8 MB | 层间中间平面 |
| scratch B（奇层写） | `0xD00000` | 8 MB | 层间中间平面 |
| IN slot1（乒乓） | `0x1500000` | 1.4 MB | 第二帧输入（可选） |

### 6.2 邮箱寄存器

| 偏移 | 名 | 方向 | 内容 |
|---|---|---|---|
| `+0x00` | IN_ADDR | ARM→FPGA | 输入张量物理地址 |
| `+0x04` | OUT_ADDR | ARM→FPGA | 输出缓冲物理地址 |
| `+0x08` | SLOT | ARM→FPGA | 槽位号 |
| `+0x0C` | CTRL | ARM→FPGA | `bit0=start`（写 1 启动；FPGA 受理后自行清 0） |
| `+0x10` | STATUS | FPGA→ARM | `bit0=busy`、`bit1=done`、`bit2=err`（`0x6` 表示 done+err） |
| `+0x14` | LAYER | ARM→FPGA | `bit[7:0]`=停止层、`bit8`=跳 ReLU、`bit9`=跳池化 |

握手顺序（必须严格遵守）：**先写 CTRL=0 并确认，再写配置寄存器，最后写 CTRL=1**。FPGA 侧的"武装"逻辑只有在见过 `CTRL bit0=0` 之后才接受下一次启动；这是为了防止上电残留的随机 CTRL 值被当成启动命令（否则 FSBL 阶段就会开始跑垃圾帧、抢占 DDR 带宽，把 ARM 侧读 SD 卡拖死）。

### 6.3 量化常量

| 项 | 值 |
|---|---|
| 输入 | `int8[3][480][1024]`，NCHW，RGB，`s_in=1/127`，zp=0（等价 `v>>1`） |
| 输出特征图 | `int8[96][15][32]`，`s_out=0.1372978389` |
| 调试口径（跳池化） | `int8[96][30][64]`（`LAYER=0x2FF`） |
| 再量化 | `y = clamp(round(acc32 × s_in × s_w[c] / s_out), -128, 127)`，整数乘移位 `Mc = round(·×2^F)` |
| 乘数定点位宽 F | 各实现自洽即可：开发链取 **F=24**，现役交付位流取 **F=31**。两条链各自对自家参考**位级一致**；互比时约 0.9% 元素相差 ±1，分类结论不变 |

---

## 7. 快速开始

### 7.1 模型侧（PC / GPU）

```bash
cd MFL_2DCNN
pip install -r requirements.txt && python check_env.py          # 环境自检（含 GPU/数据/缓存）
python preprocess_tar.py --split-name train                     # 数据流式预处理成 1024×480 缓存
python train.py && python evaluate.py                           # 训练 + 测试集评估
python quantize_export.py && python compare_int8.py             # INT8 量化 + 掉点对比
python export_test_vectors.py                                   # 逐层对拍向量（给 FPGA/ARM）
```

数据来源：`https://hf-mirror.com/datasets/PipeMFL/PipeMFL-240K`（12 类检测标注，按 MTL 面积比换算成三分类）。

### 7.2 Web 大屏

```bash
cd MFL_Web
pip install -r backend/requirements.txt && python backend/app.py --port 8080   # Flask 参考实现
# 或 Go 版本（与板端同一份代码）
bash backend/go/build.sh && backend/go/bin/mflweb.exe
# 浏览器打开 http://127.0.0.1:8080
```

### 7.3 板端部署

```bash
# ① 启动镜像：位流放第 2 分区（booter.exe + .icf 打包 BOOT_PG.bin），拷到 SD 卡 BOOT 分区
# ② Web 后端
scp backend/go/bin/mflweb-board.tar.gz root@<板IP>:/root/
ssh root@<板IP> "mkdir -p /root/mflweb && gzip -dc /root/mflweb-board.tar.gz | tar -x -C /root/mflweb"
ssh root@<板IP> "cd /root/mflweb && chmod +x mflweb-linux-arm64 run.sh && ./run.sh"
# ③ 推理程序（静态交叉编译产物）
scp app_arm weights/mfl_head.bin root@<板IP>:/root/
ssh root@<板IP> "cd /root && ./app_arm --reg-base 0x301000 --health-wait 0"
# ④ 验证
ssh root@<板IP> "wget -qO- http://127.0.0.1:8080/api/health"
# PC 浏览器：http://<板IP>:8080
```

交叉编译：用厂商 Ubuntu VM 内的 `aarch64-linux-gnu-gcc 7.5.0`（配套板载 glibc 2.25），加 `-O2 -static`。

### 7.4 重建 FPGA 位流

```bash
# PDS 2025.2-ads，器件 PG2K100-6IMBG400
# 1) 新建工程，加入 rtl/ 与 mem/（PDS 期望 mem/ 在工程工作目录的上一级）
# 2) 约束用 project/Kosmo2_mfl_cnn_accel.fdc（sys_clk 20ns + create_generated_clock pll_clk_50m）
# 3) compile → synthesize → dev_map → place → route → route_optimize → report_timing → gen_bit_stream
# 4) tools/check_pa.py 校验打包镜像里的 PA 分区
```

细节见 [`MFL_FPGA/MFL_FPGA/README.md`](MFL_FPGA/MFL_FPGA/README.md)。

**现役交付件**（`MFL_FPGA/MFL_FPGA/bitstream/`，可直接上板，不必重建）：

| 文件 | 大小 | md5 |
|---|---|---|
| `AXI_wrapper.sbit`（生产位流） | 3,333,784 B | `1a1847edee0196d1ba0095d1a5ed89c9` |
| `BOOT_PG.bin`（启动镜像） | 18,286,592 B | `ccb6fd8fb27aafdc9499ce2338afdb3a` |

重新打包启动镜像：`booter.exe -image board_tools\m9_boot_prod.icf`，再用
`python tools/check_pa.py <new.sbit> out_prod\BOOT_PG.bin` 确认输出 `PA bitstream found at 0x1B800`。

---

## 8. 精度与性能实测

| 项 | 数值 | 备注 |
|---|---|---|
| FP32 测试集 | acc 72.9%、macro-F1 0.599、severe 召回 78.4% | 48,064 张；类别不均衡（75/18/6%），指标以 severe 召回为主 |
| INT8 量化 | argmax 一致率 97.8%，acc 无掉点 | Entropy 校准 2048 样本 |
| 定点链复算 | 各自参考下 10 层逐元素 **0 差** | F=24 链与 F=31 链都对自家金标准位级一致；两条链互比 99.06% 相同、max\|Δ\|=1 |
| 板上特征图 | 46,080 B **逐字节相同** | 与各自定点金标准比对（满尺寸全链多次复现） |
| 端到端分类 | 99/100 与 PC 参考一致；114/114 帧运行成功 | 唯一分歧帧为并列/边界情况 |
| 单帧时延 | 5.76 s（FPGA）+ ~0.17 s（ARM）= 5.93 s | 50 MHz 时钟 |
| 拍序效率 | 287.85 M 忙周期 vs 理想 215.3 M（1.34×） | MAC 利用率约 21%，优化空间在调度 |
| 资源占用 | LUT 47.6%、DRM 96.2%、APM 68/256 | DRM 已近满，进一步加通道需先解决存储 |
| Web 一致性 | Go 与 Flask 两实现 23/23 项行为一致 | `tools/conformance.py` 自动比对 |

---

## 9. 已知限制与注意事项

1. **位流只能随 BOOT 镜像加载**（板上无 `fpga_manager`），换位流 = 重打启动镜像 + 重新上电。
2. **位流必须是启动镜像第 2 分区**，否则会被当成数据段覆盖 BL31/u-boot 暂存区。打包规则见 `MFL_FPGA/MFL_FPGA/board_tools/`。
3. **上电必须先清邮箱**：残留 CTRL/STATUS 会让第一帧直接报 `err`，起跑前写 `CTRL=0`、`STATUS=0`。
4. **无中断**：PU↔PA 共享窗设备树节点没有 `interrupts` 属性，完成通知靠 1 ms 轮询（对 5+ s/帧的负载开销可忽略）。
5. **单引擎串行**：FPGA 同一时刻只处理一帧，"乒乓双槽"式提交会被丢弃，ARM 侧必须"提交前排干在跑的槽"。
6. **DRM 96.2%**：片内 36Kb DRAM 只剩约 5.5 块余量，再加层/加通道必须先解决权重存储（分段、量化位宽或外部存储）。
7. **板上没有 Python/gcc**：所有板端程序必须是静态二进制；Web 后端用 Go 纯标准库实现。
8. **调试导出地址不能与输入平面重叠**，否则会自覆盖出"尾部全错"的假象（工具已加守卫）。

---

## 10. 文档索引

| 文档 | 内容 |
|---|---|
| [`MFL_2DCNN/README.md`](MFL_2DCNN/README.md) | 数据集与标签口径、训练/量化/导出全流程、模型配比与 BRAM 预算、FAQ |
| [`MFL_FPGA/MFL_FPGA/README.md`](MFL_FPGA/MFL_FPGA/README.md) | RTL 模块划分、`.mem` 生成、PDS 重建位流、仿真方法、板端复跑 |
| [`MFL_ARM/README.md`](MFL_ARM/README.md) | ARM 前半/后半分工、源码与二进制清单、上板命令、权重格式 |
| [`MFL_ARM/03_docs/FPGA组对接地址表.md`](MFL_ARM/03_docs/FPGA组对接地址表.md) | DDR 轮询邮箱契约（寄存器/地址/状态机/时序）的完整定义 |
| [`MFL_Web/README.md`](MFL_Web/README.md) | 大屏功能、板端部署、18 个 HTTP 接口、告警规则、离线阈值 |
| [`MFL_Web/docs/API.md`](MFL_Web/docs/API.md) | 接口字段级契约（请求/响应/SSE/裸 socket C 示例） |
| [`Global_Docs/BOARD_AUDIT.md`](Global_Docs/BOARD_AUDIT.md) | 开发板实测核查档案：SoC 参数、系统实测、UIO 通道、启动链、工具链 |

---

## 11. 术语

| 缩写 | 含义 |
|---|---|
| MFL | 漏磁（Magnetic Flux Leakage），本项目处理的是它的伪彩可视化图像 |
| PA / PU | 可编程阵列（FPGA 侧）/ 处理单元（ARM 侧），PG2K100 的异构两部分 |
| 停层（stop layer） | 让 FPGA 只算到第 N 层就写回，用于逐层对拍 |
| 金标准（golden） | PC 端定点链算出的逐层/全链参考数据，一切对拍锚点 |
| GAP | 全局平均池化，把 96×15×32 压成 96 维 |
| Mc / F | 再量化的整数乘数与乘数定点位宽（开发链 F=24、现役交付链 F=31，各自自洽） |
| severity | 腐蚀严重度 0/1/2 = 无/轻度/重度，与 Web 颜色绿/黄/红对应 |
