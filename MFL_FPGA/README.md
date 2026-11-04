# MFL FPGA —— MFL 腐蚀识别边缘检测系统 · FPGA(PA) 侧

紫光同创 **PG2K100**（Kosmo2-MES2K100：PA 阵列 + 双核 A53）上实现的 **10 层 int8 卷积
特征提取引擎**（3×3 / pad=1 / stride=1，权重全片上驻留），经 **SPS0↔DDR 共享窗**与
ARM 侧 DDR 邮箱交互；ARM 负责解码/量化（前半）与 GAP+FC+softmax（后半）。

**当前状态（2026-10-29 签核位流，板上验证）**：

| 项 | 值 |
|---|---|
| 全链耗时 | **5.76 s/帧**（实测 5760/5761/5762 ms @50 MHz，= 仿真 287.85M 忙拍） |
| 批量端到端 | **114/114 帧 ok**（ARM 前端→FPGA→head→Web），5.93 s/帧含全链 |
| 精度一致性 | **99/100 vs PC 参考**；唯一分歧 P0728 为决策边界帧（特征对整数金标准 100% 逐位相同） |
| 双帧 / 软复位 | 1 深 pending + 500 ms DONE/OUT guard（hold 实测 500 ms）；软复位 2 ms 自清 |
| P&R 签核 | 50 MHz / **WNS +3.429 ns** / WHS +0.056 / 0 failing / Est 60.35 MHz |
| 资源 | DRM 138.5/144（97%）、LUT 25,504、FF 22,390、APM 68 |

## 目录结构

```
rtl/          26 个设计 .v：M2(DMA 读/写主 + SPS0 桥组) M3(行缓冲) M4(乘加阵列)
              M5(再量化/池化) M6(单层引擎) M7(片上参数仓库) M8(层序/边界)
              M9(邮箱适配器/AXI 主/mux/顶层/板级 wrapper)
mem/          综合期 $readmemh 加载的 ROM：conv00..09_w.mem（权重）、layer_cfg.mem
              （10 层配置）、b/mc.mem（bias/Mc 生成源）、CRC/manifest —— 必须入库
sim/          15 个 testbench + SPS0 行为模型 + 12 个 ModelSim .do
project/      PDS 工程定义：.pds + .fdc（时序约束）+ block_editor（AXI.pbs、
              wrapper、PLL 50MHz、PU IP wrapper）
tools/        仿真包装 run_sim.py、各向量/ROM 生成器（gen_m7_wram / gen_m8_cfg /
              gen_m9_full_vec ...）、打包校验 check_pa.py、audit_v2.py
board_tools/  板端工具源码（免 libc，静态 aarch64）：m9_full（probe/boot/full/
              dual/export/dump/softreset）、mbox_gate_test、bist_check、
              BOOT 打包单 .icf ×3
bitstream/    当前生产位流 AXI_wrapper.sbit（md5 1a1847ed…）与启动镜像
              BOOT_PG.bin（18,286,592 B，PA 分区 @0x1B800）
```

各模块职责见 `rtl/` 各文件的头部注释（模块按 M1…M9 编号）；数据通路、邮箱协议与 DDR 布局见仓库根 `README.md` §2、§6。

## 重建位流（PDS 2025.2-ads，器件 PG2K100-6IMBG400）

1. 新建 PDS 工程，把 `rtl/`（M2..M9）、`mem/`、`project/block_editor/` 的源加入工程
   ——注意两点：**PDS 期望 `mem/` 位于工程工作目录的上一级**（ROM 路径 `../../mem/...`）；
   PLL 与 PU IP 是 block_editor 内的 IP 核，需按 `project/block_editor/AXI/` 下的源重建；
2. 约束用 `project/Kosmo2_mfl_cnn_accel.fdc`（sys_clk 20 ns + `create_generated_clock
   pll_clk_50m`，缺这条 PLL 会被推断成 1 MHz 假绿）；
3. 跑 `compile → synthesize → dev_map → place → route → route_optimize →
   report_timing → gen_bit_stream`，检查点见仓库根 `README.md` §7.4 与 `bitstream/README.md` 里的 P&R 签核记录；
4. 生成位流后用 `tools/check_pa.py` 校验打包镜像里的 PA 分区（`board_tools/*.icf` +
   booter.exe 打 BOOT_PG.bin）。

## 仿真

```bash
python tools/run_sim.py --ip ip/kosmo2_m9_top --with ip/kosmo2_ctrl_fsm ... --do sim_m9_top.do
# TB 打印 TB PASS 才算过；依赖注入等选项见 python tools/run_sim.py --help
```

说明：本仓库 `sim/` 是从开发工作区各 IP 收集的**扁平副本**（TB + 模型 + 脚本）；
`run_sim.py` 按工作区布局（`ip/<名>/{rtl,sim,mem}`）取文件，跑仿真时把本仓库内容映射回
该布局，或按 `run_sim.py --help` 给出的布局参数直接执行。大向量（满尺寸 in/exp hex，3 MB/份）
不入库，先跑生成器：`gen_m7_wram.py`（权重 ROM）→ `gen_m8_cfg.py`（层配置）→
`gen_m9_full_vec.py`（满尺寸金标准，`--sample/--out-dir` 可换样本）。

## 板端复跑（Kosmo2-MES2K100，root@192.168.1.10，/dev/uio0）

```bash
# 交叉编译（PDS EDK 裸机链，Windows 可直接编；见 board_tools/README_工具说明.md）
aarch64-none-elf-gcc -nostdlib -static -ffreestanding -O2 -Wl,-e,_start -o m9_full m9_full.c
# 端到端对拍：写 IN → LAYER=0xFF → 轮询 → 46,080 B 逐字节比对（期望 ALL MATCH，busy≈5761ms）
./m9_full full m9_in_sample0.bin m9_exp_sample0.bin
```

上电顺序与 LED 语义见仓库根 `README.md` §4.1、§9；双帧/软复位/批量操作见 `board_tools/README_Toolsuse.md`。

