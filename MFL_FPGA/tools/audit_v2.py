# -*- coding: utf-8 -*-
"""
audit_v2.py -- 2026-10-15 v2 交付独立复核（test_vectors + quant_export）
检查项:
  A. np.load 可读性(NPY 魔数) / 文件齐全 / shape 与 fpga_architecture_spec 一致
  B. manifest 的 in/out scale 与 quant_export quant_params 逐层一致性
  C. int8 链闭合: conv(k+1)_in == requant(relu((pool) conv(k)_out))  (Mc=round(ratio·2^F))
     同 scale 边界应为逐元素直通; 异 scale 边界 |Δ|<=1
  D. 输出可复算: conv(k)_out_int8 == clamp(round((Σx·w + b)·s_in·s_w/s_out)) 用新 quant_export
     参数(BN 折叠版) + 我们的 round-half-up 口径 —— 这是 FPGA 主契约的可验证性
  E. 权重代次: 反解有效权重倍率 k_c 是否已≈1（v1 时代为 1.39/2.38 的 BN 未折叠伪影）
  F. 末层语义: relu+pool(conv09_out) 是否全非负、shape 是否 96x15x32（重算, 不依赖断言）
  G. 池化次数/边界比例表与 shape 链自洽
输出: 打印 + doc\新向量审计_v2_report.txt
"""
import numpy as np
import json
import io
import os
import sys

TV = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors'
QE = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
SMP = os.path.join(TV, 'sample_0_Train_A_0000053')
F = 31
out = io.StringIO()

def P(*a):
    s = ' '.join(str(x) for x in a)
    print(s)
    out.write(s + '\n')

def load(p):
    return np.load(p)

# ---------- A ----------
P('=' * 72)
P('A. 可读性 / 文件 / shape')
mf = json.load(open(TV + r'\manifest.json', encoding='utf-8'))
qp = json.load(open(QE + r'\quant_params.json', encoding='utf-8'))
sp = json.load(open(QE + r'\fpga_architecture_spec.json', encoding='utf-8'))
lt = mf['layers_table']
with open(os.path.join(SMP, 'conv00_out_int8.npy'), 'rb') as f:
    magic = f.read(8)
P('  magic bytes:', magic.hex(), '(标准 NPY: 934e554d50590100)')
x0 = load(os.path.join(SMP, 'conv00_in_int8.npy'))
y9 = load(os.path.join(SMP, 'conv09_out_int8.npy'))
P('  conv00_in_int8 shape', x0.shape, x0.dtype, ' conv09_out_int8 shape', y9.shape, y9.dtype)
nfiles = len(os.listdir(SMP))
P('  样本内文件数:', nfiles, '(期望 42)')
shp_ok = True
for i, L in enumerate(sp['layers']):
    got = load(os.path.join(SMP, 'conv%02d_out_int8.npy' % i)).shape
    exp = (1, L['out_ch'], L['out_hw'][0], L['out_hw'][1])
    if tuple(got) != tuple(exp):
        shp_ok = False
        P('  !! conv%02d shape %s != spec %s' % (i, tuple(got), exp))
P('  shape 与 fpga_architecture_spec 一致:', shp_ok)

# ---------- B ----------
P('=' * 72)
P('B. scale 一致性 (manifest vs quant_params)')
bad = 0
for i, L in enumerate(lt):
    cl = qp['conv_layers'][i]
    d1 = abs(L['in_scale'] - cl['act_in_scale']) / cl['act_in_scale']
    d2 = abs(L['out_scale'] - cl['act_out_scale']) / cl['act_out_scale']
    if max(d1, d2) > 1e-6:
        bad += 1
        P('  !! %s in/out rel diff %.2e / %.2e' % (L['layer'], d1, d2))
P('  逐层 in/out scale rel-diff <=1e-6 的层数: %d/10 (bad=%d)' % (10 - bad, bad))
P('  input_scale: manifest %.10f vs qp %.10f' % (mf['input_scale'], qp['input']['scale']))

# ---------- G / 边界比例 ----------
P('=' * 72)
P('G. 边界比例与算子序列')
for i, L in enumerate(lt):
    r = L['boundary_ratio_to_next']
    calc = None if r is None else L['out_scale'] / lt[i + 1]['in_scale']
    ok = '' if calc is None else (' ok' if abs(calc - r) / r < 1e-6 else ' !!MISMATCH')
    P('  %s relu=%d pool=%d ratio=%s%s' % (L['layer'], L['relu_after'], L['pool_after'],
      ('%.6f' % r) if r is not None else 'None', ok))
share = [L['out_scale'] == lt[i + 1]['in_scale'] for i, L in enumerate(lt[:-1])]
P('  同 scale 边界(应为 conv02/03/05/06 之后 4 处):', [lt[i]['layer'] for i in range(9) if share[i]])

# ---------- C ----------
P('=' * 72)
P('C. int8 链闭合: conv(k+1)_in vs requant(relu((pool) conv(k)_out))')
MC_F = 24


def requant_i8(src, ratio, f=MC_F):
    Mc = int(round(ratio * (1 << f)))
    y = (src.astype(np.int64) * Mc + (1 << (f - 1))) >> f
    return np.clip(y, -128, 127).astype(np.int64)


def maxpool2x2(a):
    H, W = a.shape[-2:]
    a = a.reshape(a.shape[0], H // 2, 2, W // 2, 2)
    return a.max(axis=(2, 4))


for k in range(9):
    src = load(os.path.join(SMP, 'conv%02d_out_int8.npy' % k))[0].astype(np.int64)
    dst = load(os.path.join(SMP, 'conv%02d_in_int8.npy' % (k + 1)))[0].astype(np.int64)
    rl = np.maximum(src, 0)
    if lt[k]['pool_after']:
        rl = maxpool2x2(rl)
    r = lt[k]['boundary_ratio_to_next']
    pred = rl if abs(r - 1.0) < 1e-9 else requant_i8(rl, r)
    d = pred - dst
    tag = 'identity' if abs(r - 1.0) < 1e-9 else 'requant'
    P('  L%d->L%d (%s, ratio=%.4f): exact=%.2f%%  |d|<=1=%.4f%%  max|d|=%d'
      % (k, k + 1, tag, r, 100 * (d == 0).mean(), 100 * (np.abs(d) <= 1).mean(), np.abs(d).max()))

# ---------- D ----------
P('=' * 72)
P('D. 输出可复算 (新 quant_export 权重 + 我们的 round 口径, patch 32x32)')


def conv_patch(x, w, b, R0, C0, PS):
    IC, H, W = x.shape
    OC = w.shape[0]
    xp = np.pad(x.astype(np.int64), ((0, 0), (1, 1), (1, 1)))[:, R0:R0 + PS + 2, C0:C0 + PS + 2]
    acc = np.zeros((OC, PS, PS), dtype=np.int64)
    for kk in range(3):
        for ll in range(3):
            acc += np.tensordot(w[:, :, kk, ll].astype(np.int64),
                                xp[:, kk:kk + PS, ll:ll + PS], axes=([1], [0]))
    return acc + b.astype(np.int64)[:, None, None]


for k in [0, 1, 2, 4, 8, 9]:
    cl = qp['conv_layers'][k]
    sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']; s_out = cl['act_out_scale']
    w = load(os.path.join(QE, r'weights_int8\conv%02d_w_int8.npy' % k))
    b = load(os.path.join(QE, r'weights_int8\conv%02d_b_int32.npy' % k))
    xs = load(os.path.join(SMP, 'conv%02d_in_int8.npy' % k))
    ys = load(os.path.join(SMP, 'conv%02d_out_int8.npy' % k))
    x = xs[0] if xs.ndim == 4 else xs
    y = (ys[0] if ys.ndim == 4 else ys)
    H, W = x.shape[-2:]
    PS_eff = min(32, H - 2, W - 2)
    R0 = (H - PS_eff) // 2; C0 = (W - PS_eff) // 2
    acc = conv_patch(x, w, b, R0, C0, PS_eff)
    Mc = np.round(s_in * sw / s_out * (2.0 ** F)).astype(np.int64)
    q = (acc * Mc[:, None, None] + (1 << (F - 1))) >> F
    q = np.clip(q, -128, 127)
    t = y[:, R0:R0 + PS_eff, C0:C0 + PS_eff].astype(np.int64)
    d = q - t
    P('  %s: patch %dx%d  Mc[0..2]=%s  exact=%.2f%%  |d|<=1=%.4f%%  max|d|=%d'
      % (cl['name'], PS_eff, PS_eff, Mc[:3], 100 * (d == 0).mean(),
         100 * (np.abs(d) <= 1).mean(), np.abs(d).max()))

# ---------- E ----------
P('=' * 72)
P('E. 权重代次复核 (conv00 k_c 拟合: acc_true ~ k*acc_json + c, patch 64x64)')
cl = qp['conv_layers'][0]
sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']
w = load(os.path.join(QE, r'weights_int8\conv00_w_int8.npy'))
b = load(os.path.join(QE, r'weights_int8\conv00_b_int32.npy'))
x = load(os.path.join(SMP, 'conv00_in_int8.npy'))[0]
yf = load(os.path.join(SMP, 'conv00_out_f32.npy')).astype(np.float64)
yf = yf[0] if yf.ndim == 4 else yf
PS = 64
R0 = 100; C0 = 400
if True:
    H0, W0 = x.shape[-2:]
    PS = min(64, H0 - 2, W0 - 2)
    R0 = (H0 - PS) // 2; C0 = (W0 - PS) // 2
accj = conv_patch(x, w, b, R0, C0, PS).astype(np.float64)
acct = yf[:, R0:R0 + PS, C0:C0 + PS] / (s_in * sw[:, None, None])
ks = []
for c in range(16):
    A2 = np.stack([accj[c].ravel(), np.ones(PS * PS)], axis=1)
    sol, *_ = np.linalg.lstsq(A2, acct[c].ravel(), rcond=None)
    ks.append(sol[0])
ks = np.array(ks)
P('  k_c: mean=%.4f  min=%.4f  max=%.4f   (v1 时代为 0.076~2.354)' % (ks.mean(), ks.min(), ks.max()))

# ---------- F ----------
P('=' * 72)
P('F. 末层语义重算: relu+pool2x2(conv09_out)')
y9v = load(os.path.join(SMP, 'conv09_out_int8.npy'))[0].astype(np.int64)
feat = maxpool2x2(np.maximum(y9v, 0))
P('  feat shape', feat.shape, '(期望 (96,15,32))  min=%d max=%d  (期望全非负)'
  % (feat.min(), feat.max()))
P('  conv09_out 负值占比 %.1f%%' % (100 * (y9v < 0).mean()))

open(r'C:\Users\21889\Desktop\Kosmo2_MES2K100\doc\新向量审计_v2_report.txt', 'w',
     encoding='utf-8').write(out.getvalue())
print('\n[saved] doc\\新向量审计_v2_report.txt')
