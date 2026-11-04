# -*- coding: utf-8 -*-
"""DSH 两条自检在新向量集(BN 折叠版)上的全层验证 + f16 精确率统计"""
import numpy as np, json
from pathlib import Path

TV = Path("output/test_vectors")
man = json.loads((TV / "manifest.json").read_text(encoding="utf-8"))
qp = json.loads(Path("output/quant_export/quant_params.json").read_text(encoding="utf-8"))
F = 24
samples = sorted(p for p in TV.glob("sample_*") if p.is_dir())
L = lambda d, p: np.load(d / (p + ".npy")).astype(np.int64)
F32 = lambda d, p: np.load(d / (p + ".npy")).astype(np.float32)
pool2 = lambda a: a.reshape(a.shape[0], a.shape[1] // 2, 2, a.shape[2] // 2, 2).max(axis=(2, 4))

print("=== 自检1: conv(k)_in == requant(relu((pool) conv(k-1)_out))  [DSH 判据, Mc 整数语义] ===")
rows = []
for d in samples:
    for i in range(9):
        o = L(d, f"conv{i:02d}_out_int8")[0]
        t = np.maximum(o, 0)
        if i % 2 == 1:
            t = pool2(t)
        ratio = man["conv_out_scale"][i] / man["conv_in_scale"][i + 1]
        Mc = int(np.round(ratio * (1 << F)))
        ref = np.clip((t * Mc + (1 << (F - 1))) >> F, -128, 127)
        v = L(d, f"conv{i+1:02d}_in_int8")[0]
        ex = (ref == v).mean() * 100
        ok = (np.abs(ref - v) <= 1).mean() * 100
        rows.append((f"L{i}->L{i+1}", d.name[-10:], ex, ok))
agg = {}
for name, s, ex, ok in rows:
    a = agg.setdefault(name, [0.0, 0.0, 0])
    a[0] += ex; a[1] += ok; a[2] += 1
for name, (ex, ok, n) in agg.items():
    print(f"  {name}: 精确一致 {ex/n:.3f}%   |Δ|<=1 {ok/n:.3f}%")

print("\n=== 自检2: conv(k)_out == requant(conv 于 conv(k)_in)  [in 反推 out, 全 10 层] ===")
for d in samples[:1]:
    for i in range(10):
        Lc = qp["conv_layers"][i]
        ic, oc = Lc["w_shape"][1], Lc["w_shape"][0]
        x = L(d, f"conv{i:02d}_in_int8")[0]
        w = np.load(f"output/quant_export/weights_int8/conv{i:02d}_w_int8.npy").astype(np.int64)
        b = np.array(Lc["bias_int32"], dtype=np.int64)
        H, W = x.shape[1], x.shape[2]
        xp = np.pad(x, ((0, 0), (1, 1), (1, 1)))
        acc = np.zeros((oc, H, W), dtype=np.int64)
        for k in range(9):
            ki, kj = divmod(k, 3)
            for c in range(ic):
                acc += xp[c, ki:ki + H, kj:kj + W][None, :, :] * w[:, c, ki, kj].reshape(oc, 1, 1)
        acc += b.reshape(oc, 1, 1)
        sw = np.array(Lc["weight_scale"], dtype=np.float64).reshape(oc, 1, 1)
        ref = np.clip(np.round(acc * Lc["act_in_scale"] * sw / Lc["act_out_scale"]), -128, 127)
        v = L(d, f"conv{i:02d}_out_int8")[0]
        ex = (ref == v).mean() * 100
        ok = (np.abs(ref - v) <= 1).mean() * 100
        print(f"  conv{i:02d}: 精确一致 {ex:.2f}%   |Δ|<=1 {ok:.3f}%   max|Δ| {np.abs(ref-v).max()}")

print("\n=== f16 存储噪声定量: 精确率 vs ±1 率（回答 99% vs 100% 之问）===")
d = samples[0]
for nm in ["conv00_out", "conv09_out", "conv05_in"]:
    a = F32(d, f"{nm}_f32"); b = L(d, f"{nm}_int8")
    s = man["conv_out_scale" if "out" in nm else "conv_in_scale"][int(nm[4:6])]
    exact = (np.clip(np.round(a / s), -128, 127) == b).mean() * 100
    ok = (np.abs(np.clip(np.round(a / s), -128, 127) - b) <= 1).mean() * 100
    print(f"  {nm}: 精确一致 {exact:.3f}%   |Δ|<=1 {ok:.3f}%")
