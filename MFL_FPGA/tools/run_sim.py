#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_sim.py - ModelSim 运行包装器
解决 ModelSim 10.5b（ModelSim-Intel FPGA Starter）无法处理中文路径的问题：
把 IP 的 rtl/ 与 sim/ 拷贝到纯 ASCII 临时目录后调用 vsim，输出实时转发。

用法:
  python tools/run_sim.py --ip ip/kosmo2_pu_ddr_bridge --do sim_access.do
  python tools/run_sim.py --ip ip/kosmo2_divider --do sim_divider.do --keep
可选环境变量: MODELSIM_BIN（默认 D:/modelsim/win64，本机 ModelSim SE 2020.4）
退出码: 0=所有 TB PASS，1=存在 FAIL/TIMEOUT/编译错误
"""
import os, sys, shutil, subprocess, argparse, re

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True, help='IP 根目录（含 rtl/ sim/）')
    ap.add_argument('--do', required=True, help='sim/modelsim 下的 .do 脚本名')
    ap.add_argument('--with', dest='with_dirs', action='append', default=[],
                    help='依赖 IP 目录(可多次): 其 rtl/*.v 并入临时 rtl/ 一起编译, 用于跨 IP 仿真(如回环 TB)')
    ap.add_argument('--keep', action='store_true', help='保留临时目录')
    ap.add_argument('--gui', action='store_true', help='打开 GUI 而非 -c')
    a = ap.parse_args()

    ip_root = os.path.abspath(a.ip)
    ip_name = os.path.basename(ip_root.rstrip('\\/'))
    ms_bin = os.environ.get('MODELSIM_BIN', r'D:/modelsim/win64')
    vsim = os.path.join(ms_bin, 'vsim.exe')
    if not os.path.isfile(vsim):
        print('找不到 vsim: %s（可设 MODELSIM_BIN 环境变量）' % vsim)
        return 2

    # ASCII 安全的临时工作目录
    base = os.environ.get('TEMP', r'C:\temp')
    work = os.path.join(base, 'kosmo2_sim', ip_name)
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(work, exist_ok=True)
    shutil.copytree(os.path.join(ip_root, 'rtl'), os.path.join(work, 'rtl'))
    shutil.copytree(os.path.join(ip_root, 'sim'), os.path.join(work, 'sim'))
    # 可选 ip/mem/（$readmemh 初始化数据）: 合并拷到 work/mem,
    # RTL 内的相对路径 ../../mem/xxx.mem 在 sim/modelsim 下可解析。
    # 主 IP 与所有 --with 依赖的 mem/ 都合并（文件名不得冲突; M8 需要 M7 的权重 .mem）
    mem_dst = os.path.join(work, 'mem')
    os.makedirs(mem_dst, exist_ok=True)
    mem_srcs = [ip_root] + [os.path.abspath(d) for d in a.with_dirs]
    for src_root in mem_srcs:
        mdir = os.path.join(src_root, 'mem')
        if os.path.isdir(mdir):
            for f in os.listdir(mdir):
                fp = os.path.join(mdir, f)
                if os.path.isfile(fp):
                    shutil.copy2(fp, os.path.join(mem_dst, f))
    # 依赖 IP 的 rtl 并入同一临时 rtl/（相对路径 ../../rtl/xx.v 继续可用）
    for dep in a.with_dirs:
        dep_rtl = os.path.join(os.path.abspath(dep), 'rtl')
        if not os.path.isdir(dep_rtl):
            print('依赖目录缺少 rtl/: %s' % dep_rtl)
            return 2
        for f in os.listdir(dep_rtl):
            shutil.copy2(os.path.join(dep_rtl, f), os.path.join(work, 'rtl', f))

    do_src = os.path.join(work, 'sim', 'modelsim', a.do)
    if not os.path.isfile(do_src):
        print('找不到 do 脚本: %s' % do_src)
        return 2

    cwd = os.path.join(work, 'sim', 'modelsim')
    # 批量模式由包装器追加 quit -f; GUI 模式不加, 方便用户看完 wave 再手动退出
    do_cmd = 'do ' + a.do + ('' if a.gui else '; quit -f')
    cmd = [vsim] + ([] if a.gui else ['-c']) + ['-do', do_cmd]
    print('>> 运行目录: %s' % cwd)
    print('>> %s' % ' '.join(cmd))
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=1,
                            universal_newlines=True, errors='replace')
    tail = []
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        tail.append(line)
    proc.wait()

    text = ''.join(tail)
    fails = len(re.findall(r'TB FAIL', text))
    passes = len(re.findall(r'TB PASS', text))
    errors = len(re.findall(r'\*\* Error', text))
    print('>> 汇总: TB PASS x%d, TB FAIL x%d, 编译/运行错误 x%d'
          % (passes, fails, errors))
    rc = 0 if (fails == 0 and errors == 0 and passes > 0) else 1
    if not a.keep:
        shutil.rmtree(os.path.join(base, 'kosmo2_sim', ip_name),
                      ignore_errors=True)
    return rc

if __name__ == '__main__':
    sys.exit(main())
