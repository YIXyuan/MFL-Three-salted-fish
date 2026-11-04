# -*- coding: utf-8 -*-
"""向量验收 5: int8 链复算 conv00 (审计§附录.4 公式含 s_w[c], |Δ|<=1 >99.9% 门槛)"""
import numpy as np, json
from pathlib import Path

qp = json.loads(Path("output/quant_export/quant_params.json").read_text(encoding="utf-8"))
d = Path("output/test_vectors/sample_0_Train_A_0000053")

x8 = np.load(d / "input_int8.npy").astype(np.int64)[0]      # (3,480,1024)
w8 = np.load("output/quant_export/weights_int8/conv00_w_int8.npy").astype(np.int64)
L0 = qp["conv_layers"][0]
b32 = np.array(L0["bias_int32"], dtype=np.int64)
sw = np.array(L0["weight_scale"], dtype=np.float64).reshape(16, 1, 1)
xpad = np.pad(x8, ((0, 0), (1, 1), (1, 1)))                 # (3,482,1026)

acc = np.zeros((16, 480, 1024), dtype=np.int64)
for k in range(9):
    ki, kj = divmod(k, 3)
    for ic in range(3):
        patch = xpad[ic, ki:ki + 480, kj:kj + 1024]         # (480,1024)
        acc += patch[None, :, :] * w8[:, ic, ki, kj].reshape(16, 1, 1)
acc += b32.reshape(16, 1, 1)

ref = np.clip(np.round(acc * L0["act_in_scale"] * sw / L0["act_out_scale"]), -128, 127)
v = np.load(d / "conv00_out_int8.npy").astype(np.int64)[0]
rate = (np.abs(ref - v) <= 1).mean() * 100
print(f"int8 链复算 vs 向量 conv00_out_int8: |Δ|<=1 一致率 = {rate:.3f}%   max|Δ| = {np.abs(ref - v).max()}")
