# -*- coding: utf-8 -*-
"""
板端探针: 通过 SSH 只读核查 Kosmo2-MES2K100 (PU) 上与全 C 推理链路相关的系统参数.
用法: python board_probe.py [--host 192.168.1.10] [--user root] [--password <板端密码，不入库>]

只执行只读命令, 不改动板子任何状态. 末尾输出对照仓库根 README 第 9 节（已知限制）前提的核查结论.
"""

import argparse
import sys

import paramiko

CHECKS = [
    ("系统身份", "uname -a; cat /etc/os-release 2>/dev/null | head -5; cat /proc/cmdline"),
    ("CPU(核数/特性)", "nproc; grep -m1 -E 'Features|model name' /proc/cpuinfo; "
                       "grep -m1 'processor' /proc/cpuinfo"),
    ("内存", "free -m | head -3"),
    ("存储与挂载", "df -h 2>/dev/null | head -10; "
                   "mount | grep -iE 'mmc|sd[a-z]|vfat|ext4' | head -6"),
    ("UIO 设备节点", "ls -l /dev/uio* 2>&1; ls /sys/class/uio 2>&1"),
    ("内核关键配置", "zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_UIO|CONFIG_UDMABUF|"
                     "CONFIG_FPGA_MGR|CONFIG_DMA_CMA|CONFIG_CMA=|CONFIG_DMA_SHARED_BUFFER' || "
                     "echo '(内核未导出 /proc/config.gz, 无法直接读配置)'"),
    ("设备树概览", "ls /proc/device-tree 2>/dev/null | head -25; "
                   "echo '---- reserved-memory:'; ls /proc/device-tree/reserved-memory 2>/dev/null || echo 无"),
    ("平台设备/fpga", "ls /sys/bus/platform/devices 2>/dev/null | head -20; "
                      "ls /sys/class/fpga_manager 2>/dev/null || echo '无 fpga_manager 类'"),
    ("已加载模块", "lsmod 2>/dev/null | head -15"),
    ("内核日志(uio/fpga/cma/dma)", "dmesg 2>/dev/null | grep -iE 'uio|fpga|cma|dma' | tail -20 || echo '(dmesg 不可读)'"),
    ("编译器(板上)", "which gcc cc g++ clang 2>&1; gcc --version 2>&1 | head -1"),
    ("Python(应为无)", "which python python3 pip pip3 2>&1"),
    ("图像/推理库(应为无)", "ls /usr/lib /usr/lib64 2>/dev/null | grep -iE 'jpeg|png|onnx' || echo '无 jpeg/png/onnx 库 (stb 方案成立)'"),
    ("Xenomai 实时框架", "ls /usr/xenomai 2>/dev/null | head -5; lsmod 2>/dev/null | grep -i xeno | head -5 || echo 无"),
    ("网络", "ip -4 addr show 2>/dev/null | grep -E 'inet|eth' || ifconfig 2>/dev/null | head -8"),
    ("中断概览(前12行)", "head -12 /proc/interrupts 2>/dev/null"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.10")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default=None, required=True, help="板端 SSH 密码(不写入仓库)")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(args.host, username=args.user, password=args.password,
                    timeout=args.timeout, look_for_keys=False, allow_agent=False)
    except Exception as e:
        sys.exit(f"[连接失败] {args.user}@{args.host}: {e}")
    print(f"[已连接] {args.user}@{args.host}\n" + "=" * 68)

    results = {}
    for name, cmd in CHECKS:
        try:
            _, out, err = cli.exec_command(cmd, timeout=args.timeout)
            stdout, stderr = out.read().decode("utf-8", "replace").strip(), err.read().decode("utf-8", "replace").strip()
        except Exception as e:
            stdout, stderr = f"(执行异常: {e})", ""
        results[name] = stdout
        print(f"\n----- {name} -----")
        print(stdout if stdout else "(空)")
        if stderr and "Permission" not in stderr:
            print(f"[stderr] {stderr[:200]}")

    # ---- 对照全 C 方案前提的结论 ----
    def has(text, *words):
        return all(w.lower() in text.lower() for w in words)

    print("\n" + "=" * 68)
    print("全 C 方案前提核查:")
    uio_dev, uio_cfg = "/dev/uio" in results["UIO 设备节点"], "CONFIG_UIO" in results["内核关键配置"]
    print(f"  {'OK ' if uio_dev else '?? '} UIO 设备节点: {'已存在' if uio_dev else '未见(/dev/uio*)'}"
          + ("" if uio_dev else (f"; 内核配置含 CONFIG_UIO={uio_cfg}" if uio_cfg else "; 内核配置不可读, 需进一步确认")))
    print(f"  {'OK ' if 'CONFIG_UDMABUF=y' in results['内核关键配置'] or 'udmabuf' in results['已加载模块'].lower() else '!!'} "
          "udmabuf 模块: " + ("可用" if ('CONFIG_UDMABUF=y' in results['内核关键配置'] or 'udmabuf' in results['已加载模块'].lower())
                          else "未启用(备选: reserved-memory + generic-uio, 或用厂商 shared-ddr UIO 通道)"))
    print(f"  {'OK ' if 'CMA' in results['内核关键配置'] else '??'} CMA/预留内存: "
          + ("配置可见" if 'CMA' in results['内核关键配置'] else "内核配置不可读, 以设备树为准"))
    print(f"  {'OK ' if has(results['编译器(板上)'], 'not found') or 'which' in results['编译器(板上)'].lower() else '??'} "
          "板上无编译器(符合预期, 用 PC 交叉编译)" if 'not found' in results['编译器(板上)'].lower()
          else f"  ?? 编译器检查: {results['编译器(板上)'][:60]}")
    print(f"  {'OK ' if 'not found' in results['Python(应为无)'].lower() or results['Python(应为无)'].strip()=='' else '!!'} "
          "板上无 Python(符合 v1.2 全 C 决策)")
    print(f"  {'OK ' if 'stb 方案成立' in results['图像/推理库(应为无)'] else '!!'} "
          "无 jpeg/png 系统库(stb_image 随源码方案成立)")
    print(f"  ?? 内存/核数: 见上方 free / nproc (预处理双缓冲+推理 ~5MB 级, 无压力)")
    cli.close()


if __name__ == "__main__":
    main()
