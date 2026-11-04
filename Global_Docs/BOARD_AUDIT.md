# Kosmo2-MES2K100 开发板硬件核查档案（BOARD_AUDIT）

> 核查时间：2026-09 ｜ 核查方式：SSH 只读探针（`board_probe.py`，root@192.168.1.10）+ 配套资料文本核读
> 用途：作为其他组员的**先提知识底稿**。所有"实测"条目均为板端命令输出；
> 引用本文时注意标注条目性质（实测 / 资料核实 / 推断）。
> 项目上下文：MFL 腐蚀识别 2D-CNN（MFL-2DCNN），FPGA(PA) 跑卷积 + ARM(PU) 跑分类头的异构推理，全 C 开发。

---

## 1. 板卡与 SoC 概览

| 项 | 内容 | 来源 |
|---|---|---|
| 板卡 | 小眼睛 Kosmo2-MES2K100（配套资料/手册均为中文，厂商 PDS 工具链） | 资料包 |
| SoC | 紫光同创 PG2K100（Kosmo-2 架构，28nm，ZYNQ 类 SoC：PA 可编程阵列 + PU 处理单元） | 参数表 xlsx |
| PA(FPGA) | 逻辑单元 85,760 ／ LUT 53,600 ／ FF 107,200 ／ 分布式 RAM 793Kb(≈99KB) ／ **块 RAM 144×36Kb = 5.06Mb ≈ 632KB** ／ **APM(乘加硬核) 256 个** ／ 无 HSST、无 PCIe ／ MIPI D-PHY 2收2发 | 参数表 xlsx |
| PU(ARM) | **双核 Cortex-A53 @1GHz**，NEON/FPU，L1 32KB+32KB，L2 512KB，片上 OCM 256KB | 参数表 xlsx |
| 板载 DRAM | **DDR3 SDRAM 16bit**，接 PU 存储控制器；**实测可用 412MB → 总容量 512MB**（早期"1~2GB"推断作废） | 手册 1.2.4 节 + 实测 free |
| 外设 | 千兆网 eth0(dwc-eth-dwmac)、USB2.0 OTG、SD(SDHCI+ADMA)、SPI、UART(ns16550a)、GPIO(pu_key/pu_led)、watchdog | 实测设备树 |

## 2. 实测系统参数（SSH 探针，2026-09）

```
内核:      Linux 5.10.0 #1 SMP aarch64 GNU/Linux
发行版:    Buildroot 2022.08.1 (busybox init, 串口 getty, root/root)
glibc:     2.25 (交叉编译工具链必须配套, 见第 6 节)
CPU:       nproc=2; Features: fp asimd evtstrm aes pmull sha1 sha2 crc32 (NEON 可用)
内存:      total 412MB, used 19MB, free 365MB (另 buff/cache 28MB)
存储:      /dev/root = /dev/mmcblk0p2, ext4, 56.7G 总量 / 53.7G 空闲 (测试图像可直接放入)
网络:      eth0 = 192.168.1.10/24 (dwc-eth-dwmac, 32bit DMA width); SSH root/<密码见内部交付> 已验证可连
网络通道:  PC(Win) --paramiko/ssh--> 板子, ping 延迟 0ms (直连网线)
cmdline:   console=ttyS0,115200 earlycon=ns16550a,mmio32,0xe5000000 root=/dev/mmcblk0p2 rootwait rw
```

**板上没有的**：gcc/cc/g++（任何编译器）、python/pip、libjpeg/libpng/onnxruntime/opencv。
**板上有用的**：ssh/scp/tftp/wget/curlftpfs、vsftpd 配置、/dev/mem（root 权限）。
**结论**：应用全 C + 依赖随源码（stb_image 单头库）+ PC 交叉编译 + scp 部署。

## 3. PU↔PA 共享通道（本项目最关键发现）

```
/dev/uio0  ←→  平台设备 300000.shared-ddr
  uio name:      "pu-pa-ddr"
  驱动:          uio_pdrv_genirq
  DT 节点:       /shared-ddr@300000, compatible "generic-uio"
  映射区域:      map0: addr=0x00000000_00300000, size=0x04000000 (64 MiB)
  语义:          PU(mmap /dev/uio0) 与 PA(AXI 访问同一 DDR 物理地址段) 共享的窗口
```

- **中断现状**：该 DT 节点**没有 interrupts 属性** → genirq 无中断可投递（实测 write /dev/uio0
  报 Invalid argument，/proc/interrupts 无 uio 行）。**v1 用轮询**（ARM 读 FPGA STATUS 寄存器，
  1ms 级间隔）；**v2 上中断**：FPGA 组把 done 接到 GIC 空闲线 + DT 补 `interrupts` 属性 +
  pango 流程重打包 BOOT。
- **GICv2 中断现状**（/proc/interrupts 摘录）：eth0=59, mmc0=53, dmac=45, ttyS0=34,
  watchdog=32, arch_timer=30；大量 SPI 线号空闲可供 FPGA done 使用。

## 4. 内核配置与预留内存（实测）

```
CONFIG_UIO=y  CONFIG_UIO_PDRV_GENIRQ=y  CONFIG_UIO_DMEM_GENIRQ=y   ← UIO 基础设施齐备
CONFIG_UDMABUF is not set   CONFIG_DMA_CMA is not set                ← 不需要, 勿走 udmabuf 路线
CONFIG_CMA=y  CONFIG_DMA_SHARED_BUFFER=y
```

设备树预留内存（shared-dma-pool，属 OpenAMP/remoteproc 风格，本项目不占用）：
- `rproc@1e000000` 4MiB（0x1e000000 起，即 ddr@1e000000 区域）
- `rpu0vdev0vring0@1e800000` / `vring1@1e804000` / `rpu0vdev0buffer@1e808000` 1MiB
- 设备树顶层另有 `remoteproc`、`firmware:kosmo-firmware`、`amba_pa`/`amba_pu`、`ddr@1e000000`、
  `pu_key`/`pu_led`、`clock-controller@e5006000`、`pu_key` 等节点；`lsmod` 为空（无已加载模块）。

**mfl2d_v2 缓冲布局（放进 64MiB 共享窗口内）**：IN_BUF0/1 @0x000000/0x00200000（各 2MB）、
OUT_BUF0/1 @0x00400000/0x00440000（各 256KB）；FPGA 寄存器空间走 /dev/mem 映射（基址由 FPGA 组定）。

## 5. 启动链与位流加载

- **无 fpga_manager 类**（实测）→ PA 位流**不经运行时加载**，随 BOOT 镜像上电写入。
- 启动链（UG991402 Booter 指南）：Booter 工具按 icf 打包 `BOOT_PG.bin` →
  分区类型 `bootloader`（必须 ELF，FSBL，须为第一分区）与 `datafile`（ELF 或位流）→
  Target Space 分 PU/PA 存储；支持加密/认证/TrustZone；FSBL 默认跳转**最后一个**应用分区（惯例放 bl31.elf）。
- SD 卡布局（Linux 使用指导手册）：FAT32 BOOT 区（BOOT_PG.bin、kernel Image、dtb）+ ext4 ROOTFS 区。

## 6. 开发路线与工具链（两套并存, 本项目选 Linux 路线）

| | 路线 A: 裸机/RTOS（EDK） | 路线 B: Linux（本项目采用） |
|---|---|---|
| 工具 | PDS 的 EDK(Eclipse 系): **仅 C/C++/汇编**, BSP 只有 standalone/FreeRTOS, 无 Linux 应用工程 | 厂商 Ubuntu 16.04 VM + `pango-config / pango-build / pango-package` 脚本链 |
| 工具链 | EDK 自带 aarch64-none-elf-gcc 10.2 (newlib 裸机链, 在 D:\pango\PDS_2025.2-ads\edk\toolchain\gnu\aarch64\) | **Linaro gcc-linaro-7.5.0-2019.12 aarch64-linux-gnu**（VM 内 /opt 或 kosmo2/pango_config/toolchain/，配套 glibc 2.25） |
| 调试 | CDT / OpenOCD（可 FSBL 初始化流, pa/pu 联调） | 板上 sshd + 远程 gdb 自备 |
| 脚本化 | Tcl(EShell: create_bsp/create_app...) | shell 脚本 |
| 用途 | FSBL/boot 链、裸机小程序 | **应用主战场**（文件系统/网络/动态库齐全） |

- rootfs 重建入口：`pango-build -c rootfs`（Buildroot 2022.08.1 配置可开 python3 等——本项目不需要）。
- PDS 安装：`pango\PDS_2025.2-ads`（含 PDS 综合工具 + edk/）；PDS/EDK 内嵌的 python38.dll
  仅是宿主机 GUI/gdb 自用运行时，**与目标板开发无关**。
- 关键文档路径（Kosmo2-MES2K100配套资料\）：
  - EDK 指南 `6.EDK_doc\UG991401_Embedded_Development_Kit_User_Guide.pdf`（314 页）
  - Booter 指南 `6.EDK_doc\UG991402_Booter_User_Guide.pdf`
  - Linux 指南 `1. Demo_Document\实验例程说明篇\Kosmo2-MES2K100 Linux使用指导手册_V1.0.pdf`
  - 硬件手册 `1. Demo_Document\硬件指导手册\Kosmo2-MES2K100 硬件手册_V1.0.pdf`（DDR3 16bit 章节）
  - SD 制卡 `5.SD制卡文件\sd_sh\`（restore_sd.sh / rootfs_backup.tar.gz）

## 7. 对 MFL-2DCNN 项目的结论与修正

1. **全 C 开发可行性：成立**（第 2 节全部前提实测通过）。开发栈 = 厂商 VM Linaro 7.5.0 交叉编译 → scp → 板上直跑。
2. **容量修正**：DDR3 实测 512MB；512MB 对本项目（~5MB 缓冲 + 小应用）依然充裕，但**不要在板上跑大内存程序**（如整个 onnxruntime+Python 环境——那也是当初弃板上 Python 的原因之一）。
3. **通信骨架**：mmap `/dev/uio0`（64MiB @物理 0x300000）承载数据缓冲；/dev/mem 映射 FPGA 控制寄存器；**v1 轮询 STATUS，v2 中断**（需 DT 补 interrupts 属性重打包，FPGA 组接线）。
4. **桥接职责**：ARM 组写 `fpga_if.c`（`MFL_ARM/01_frontend/01_arm_source/fpga_if.c` 有现成 mmap/轮询代码）；FPGA 组的 AXI 主/从以 0x300000 窗口为数据契约（见根目录 README 第 6 节「关键接口契约」）。
5. **[定案 2026-10-01] 控制寄存器基址 = 0x0030_1000**（共享窗内偏移 0x1000，DDR 邮箱形态，
   语义 = 本文件 fpga_regs.h；offset 0x1000~0x10FF）。FPGA 侧独占写 STATUS、受理后清 CTRL；
   ARM 现有写-1-清 done 的时序与 FPGA 侧严格交替、无竞争（分析见 Kosmo2_IP/docs/03 §1.1）。
   LAYER 寄存器（0x14）bit[7:0]=停止层、bit8=pre-ReLU 导出、bit9=跳池化（调试用）。
5. **验收锚点不变**：预处理对 `input_int8.npy`、逐层对 `convXX_out_int8.npy`（|Δ|≤1）、头对 `manifest.json` logits。

## 7b. 共享窗地址图 v3.1 修订记录（2026-10-10）

> 本节为 v3.1 地址图（物理地址）：

| 区域 | 物理地址 | 实占 | 来源 |
|---|---|---|---|
| 邮箱（6 寄存器） | 0x301000 | 64B | docs/03 §1 定案 |
| IN slot0 数据 | 0x302000 | 1.4MB | v3.1（避开邮箱页） |
| final OUT（实模式） | 0x470000 | 46,080B | v3.1（避 IN slot0 数据区；OUT_ADDR 运行时寄存器） |
| scratch A（偶层写） | 0x500000 | 8MB | RTL 参数 v3.1（容 L0 7.5MiB） |
| scratch B（奇层写） | 0xD00000 | 8MB | RTL 参数 v3.1（SCR1@0x900000 因与 L0 交叠弃用） |
| IN slot1（乒乓） | 0x1500000 | 1.4MB | 三方会签提案（scratch B 顶之上） |
| 窗顶 | 0x4300000 | — | 64MiB 共享窗末 |

## 8. 复核方法

```bash
# 只读探针(Windows/任意有 python+paramiko 的机器):
cd mfl2d_v2 && python board_probe.py            # 默认 root@192.168.1.10
# 改动内核/驱动/设备树后重跑, 与本档案对比差异; 深挖 uio0 绑定可用:
#   cat /sys/class/uio/uio0/name; cat /sys/class/uio/uio0/maps/map*/{addr,size}
```
