# -*- coding: utf-8 -*-
"""
gen_m6_tb_vectors.py -- M6 pe_layer 单元测试向量生成（一次性, 产出 ip/kosmo2_pe_layer/sim/vec/*.hex）
测试用例:
  T1 合成小层 : W=16 H=6 C_in=3 out_ch=4, 随机 int8 权重/小 bias/Mc -> 全层金模型
  T2 真实patch: conv00 真权重(v2 quant_export) + 输入 patch(6x16) -> patch 金模型
输出文件 (供 $readmemh):
  t1_wcol.hex / t2_wcol.hex   每行 512 hex = 2048bit 权重列 (t=(ky*3+kw)*C+cin 次序)
  t1_bias.hex / t2_bias.hex   每行 8 hex = 通道 bias (int32)
  t1_mc.hex   / t2_mc.hex     每行 8 hex = 通道 Mc (int32, round(s_in*s_w/s_out*2^31))
  t1_in.hex   / t2_in.hex     每行 2W hex = 一行(W 字节, 每通道每行一行; c*H+y 次序)
  t1_exp.hex  / t2_exp.hex    每行 2 hex = 期望输出字节 (c*H+y)*W + x 次序 (NCHW)
口径: q = clamp((acc*Mc + 2^30) >> 31, -128, 127), relu 后
"""
import numpy as np
import os

OUT = r'C:\Users\21889\Desktop\Kosmo2_MES2K100\ip\kosmo2_pe_layer\sim\vec'
QE2 = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
TV2 = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors\sample_0_Train_A_0000053'
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(20261016)

def conv_gold(x, w, b, F=31):
    """x:(IC,H,W) int, w:(OC,3,3,IC) int, b:(OC,) int -> (OC,H,W) int8"""
    IC, H, W = x.shape
    OC = w.shape[0]
    xp = np.pad(x.astype(np.int64), ((0, 0), (1, 1), (1, 1)))
    acc = np.zeros((OC, H, W), dtype=np.int64)
    for ky in range(3):
        for kw in range(3):
            # w[:, ky, kw, :] -> (OC, IC); xp[:, ky:ky+H, kw:kw+W] -> (IC,H,W)
            acc += np.tensordot(w[:, ky, kw, :].astype(np.int64), xp[:, ky:ky+H, kw:kw+W], axes=([1], [0]))
    return acc + b[:, None, None]

def emit_wcol(path, w, C_in):
    """w:(OC,3,3,IC) -> 每列 2048bit (oc 字节在低位起)"""
    OC = w.shape[0]
    lines = []
    for ky in range(3):
        for kw in range(3):
            for cin in range(C_in):
                v = 0
                for oc in range(OC):
                    v |= (int(w[oc, ky, kw, cin]) & 0xFF) << (8 * oc)
                lines.append('%0512x' % v)
    open(path, 'w').write('\n'.join(lines) + '\n')

def emit_i32(path, a):
    open(path, 'w').write('\n'.join('%08x' % (int(v) & 0xFFFFFFFF) for v in a) + '\n')

def emit_in(path, x):
    IC, H, W = x.shape
    lines = []
    for c in range(IC):
        for y in range(H):
            lines.append(''.join('%02x' % (int(v) & 0xFF) for v in x[c, y]))
    open(path, 'w').write('\n'.join(lines) + '\n')

def emit_exp(path, q):
    OC, H, W = q.shape
    lines = []
    for c in range(OC):
        for y in range(H):
            for v in q[c, y]:
                lines.append('%02x' % (int(v) & 0xFF))
    open(path, 'w').write('\n'.join(lines) + '\n')

def quant(acc, Mc, relu=True, F=31):
    q = (acc * Mc[:, None, None].astype(np.int64) + (1 << (F - 1))) >> F
    q = np.clip(q, -128, 127)
    if relu:
        q = np.maximum(q, 0)
    return q.astype(np.uint8)

# ---------------- T0 单位权重(输出=relu(中心像素)) ----------------
W0, H0, C0, OC0 = 16, 6, 3, 4
x0 = rng.integers(0, 128, size=(C0, H0, W0)).astype(np.int64)          # 非负
w0 = np.zeros((OC0, 3, 3, C0), dtype=np.int64)
w0[0, 1, 1, 0] = 1
b0 = np.zeros(OC0, dtype=np.int64)
Mc0 = np.zeros(OC0, dtype=np.int64); Mc0[0] = (1 << 31) - 1   # 不可用 2^31: int32 溢出
acc0 = conv_gold(x0, w0, b0)
q0 = quant(acc0, Mc0)
emit_wcol(os.path.join(OUT, 't0_wcol.hex'), w0, C0)
emit_i32(os.path.join(OUT, 't0_bias.hex'), b0)
emit_i32(os.path.join(OUT, 't0_mc.hex'), Mc0)
emit_in(os.path.join(OUT, 't0_in.hex'), x0)
emit_exp(os.path.join(OUT, 't0_exp.hex'), q0)
print('T0: 输出应等于 relu(输入像素 c0 中心)  —— 隔离扫描/对齐')

# ---------------- T1 合成小层 ----------------
W, H, C_in, OC = 16, 6, 3, 4
x = rng.integers(-128, 128, size=(C_in, H, W)).astype(np.int64)
w = rng.integers(-127, 128, size=(OC, 3, 3, C_in)).astype(np.int64)
b = rng.integers(-100000, 100000, size=OC).astype(np.int64)
Mc = rng.integers(100000, 3000000, size=OC).astype(np.int64)
acc = conv_gold(x, w, b)
q = quant(acc, Mc)
emit_wcol(os.path.join(OUT, 't1_wcol.hex'), w, C_in)
emit_i32(os.path.join(OUT, 't1_bias.hex'), b)
emit_i32(os.path.join(OUT, 't1_mc.hex'), Mc)
emit_in(os.path.join(OUT, 't1_in.hex'), x)
emit_exp(os.path.join(OUT, 't1_exp.hex'), q)
print('T1: acc range [%d, %d]  q range [%d, %d]' % (acc.min(), acc.max(), q.min(), q.max()))

# ---------------- T2 真实 conv00 patch ----------------
import json
qp = json.load(open(os.path.join(QE2, 'quant_params.json'), encoding='utf-8'))['conv_layers'][0]
sw = np.array(qp['weight_scale']); s_in = qp['act_in_scale']; s_out = qp['act_out_scale']
w2 = np.load(os.path.join(QE2, r'weights_int8\conv00_w_int8.npy')).astype(np.int64)   # (16,3,3,3)
b2 = np.load(os.path.join(QE2, r'weights_int8\conv00_b_int32.npy')).astype(np.int64)  # (16,)
x2full = np.load(os.path.join(TV2, r'conv00_in_int8.npy'))[0].astype(np.int64)        # (3,480,1024)
R0, C0, PW, PH_ = 200, 400, 16, 6
x2 = x2full[:, R0:R0 + PH_, C0:C0 + PW]                                               # (3,6,16)
Mc2 = np.round(s_in * sw / s_out * (2.0 ** 31)).astype(np.int64)
acc2 = conv_gold(x2, w2, b2)
q2 = quant(acc2, Mc2)
emit_wcol(os.path.join(OUT, 't2_wcol.hex'), w2, 3)
emit_i32(os.path.join(OUT, 't2_bias.hex'), b2)
emit_i32(os.path.join(OUT, 't2_mc.hex'), Mc2)
emit_in(os.path.join(OUT, 't2_in.hex'), x2)
emit_exp(os.path.join(OUT, 't2_exp.hex'), q2)
print('T2: Mc[0..2]=%s' % Mc2[:3])
q_pre = ((acc2 * Mc2[:, None, None] + (1 << 30)) >> 31).clip(-128, 127)
print('T2: acc range [%d, %d]  q range [%d, %d] (neg=%d -> %d after relu)'
      % (acc2.min(), acc2.max(), q2.min(), q2.max(),
         int((q_pre < 0).sum()), int((q2 == 0).sum())))
print('W_p = 9*C_in =', 9 * C_in, '/', 9 * 3)
print('vec dir:', OUT)
