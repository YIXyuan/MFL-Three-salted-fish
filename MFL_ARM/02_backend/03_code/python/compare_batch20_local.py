import sys, io, os, json, hashlib
import numpy as np
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

L = r"D:\QianSai\new\arm_head"
SRC = os.path.join(L, "test_vectors", "batch20")
OUT = os.path.join(L, "build", "batch20_out")
pids = [f"P{i:04d}" for i in range(1, 21)]
manifest = json.load(open(os.path.join(SRC, "manifest_batch20.json"), encoding="utf-8"))
cases = {x["point_id"]: x for x in manifest["cases"]}

print("== 输入一致性 (batch20 P0001 vs 板上原输入) ==")
a = open(os.path.join(SRC, "P0001_input_int8.bin"), "rb").read()
b = open(os.path.join(L, "test_vectors", "real", "P0001_001.input_int8.bin"), "rb").read()
print(f"  batch20 md5={hashlib.md5(a).hexdigest()}  size={len(a):,}")
print(f"  t2_ver  md5={hashlib.md5(b).hexdigest()}  size={len(b):,}")
print(f"  相同: {a == b}")

print(f"\n{'pid':6s} {'特征图':10s} {'maxΔ':>4s} {'pred':>4s} {'exp':>4s} {'arg':>3s} {'|Δlogit|':>8s}")
exact = within1 = arg_ok = n = 0
for pid in pids:
    fp = os.path.join(OUT, f"{pid}_out.bin")
    rp = os.path.join(SRC, f"{pid}_feat15_int8.bin")
    if not (os.path.exists(fp) and os.path.exists(rp)):
        print(f"{pid:6s} 缺文件"); continue
    f = np.fromfile(fp, dtype=np.int8).astype(np.int32)
    r = np.fromfile(rp, dtype=np.int8).astype(np.int32)
    if f.size != 46080 or r.size != 46080:
        print(f"{pid:6s} 尺寸异常 {f.size}/{r.size}"); continue
    d = np.abs(f - r)
    ex = bool((d == 0).all()); w1 = bool((d <= 1).all())
    exact += ex; within1 += w1

    csvp = os.path.join(OUT, f"{pid}.csv")
    pred = None; dlog = None
    if os.path.exists(csvp):
        lines = open(csvp, encoding="utf-8").read().strip().splitlines()
        if len(lines) >= 2:
            cols = lines[1].split(",")
            pred = int(cols[4])
            lg = np.array([float(cols[1]), float(cols[2]), float(cols[3])])
            dlog = float(np.abs(lg - np.array(cases[pid]["logits_f32"])).max())
    exp = cases[pid]["argmax_f32"]
    ok = (pred == exp)
    arg_ok += ok
    n += 1
    print(f"{pid:6s} {'100%' if ex else ('|Δ|<=1' if w1 else '差异'):10s} "
          f"{int(d.max()):>4d} {str(pred):>4s} {exp:>4d} {'✓' if ok else '✗':>3s} "
          f"{(f'{dlog:.4f}' if dlog is not None else '-'):>8s}")

print(f"\n汇总: 有效 {n}/20; 特征图逐字节相同 {exact}/{n}; |Δ|<=1 {within1}/{n}; argmax 一致 {arg_ok}/{n}")
