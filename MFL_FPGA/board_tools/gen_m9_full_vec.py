# -*- coding: utf-8 -*-
"""
gen_m9_full_vec.py -- M9 满尺寸 10 层全链仿真向量生成器（只读生成，不改 RTL）

用途:
  为 M9 满尺寸长仿真生成
    ip/kosmo2_m9_top/sim/vec_full/m9_full_in_beats.hex   1,474,560 B = 92,160 x 128bit
    ip/kosmo2_m9_top/sim/vec_full/m9_full_exp_beats.hex  46,080 B   = 2,880 x 128bit
    ip/kosmo2_m9_top/sim/vec_full/manifest.json          尺寸/CRC/层配置核对

金标准与 tools/gen_m8_cfg.py 完全同口径:
  conv:  acc = sum(x*w) + bias            (int8 x int8, int64 累加)
  第一级: q = clamp((acc*Mc + 2^30) >> 31, -128,127), 再 ReLU
  边界:   pool(2x2s2, signed max) 后 q2 = clamp((q*McB + 2^23) >> 24, -128,127)
          ratio==1 免换挡（McB=2^24 恒等）
  末层 conv09: relu + pool -> int8[96][15][32] = 46,080 B

注意:
  * 卷积用 float64 计算。输入/权重都是 int8，累加最大约 9*96*127*127 < 2^24，
    远小于 2^53，float64 结果仍是精确整数；随后 rint 回 int64 再做整数 requant。
  * 该脚本只生成满尺寸向量，不覆盖 scaled 回归用的 sim/vec/。
"""
import json
import os
import sys
import time
import zlib

import numpy as np

ROOT = r'C:\Users\21889\Desktop\Kosmo2_MES2K100'
QE = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
TV = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors'

# 可选参数（不带参数时行为与旧版完全一致：sample_0 -> ip/kosmo2_m9_top/sim/vec_full）
#   python tools/gen_m9_full_vec.py [--sample <样本目录名>] [--out-dir <输出目录>]
_arg_sample = None
_arg_outdir = None
_argv = sys.argv[1:]
_i = 0
while _i < len(_argv):
    if _argv[_i] == '--sample' and _i + 1 < len(_argv):
        _arg_sample = _argv[_i + 1]
        _i += 2
    elif _argv[_i] == '--out-dir' and _i + 1 < len(_argv):
        _arg_outdir = _argv[_i + 1]
        _i += 2
    else:
        raise SystemExit('usage: gen_m9_full_vec.py [--sample <name>] [--out-dir <dir>]')

SMP = os.path.join(TV, _arg_sample) if _arg_sample else os.path.join(TV, 'sample_0_Train_A_0000053')
CFG_MEM = os.path.join(ROOT, 'ip', 'kosmo2_ctrl_fsm', 'mem', 'layer_cfg.mem')
OUT_DIR = _arg_outdir if _arg_outdir else os.path.join(ROOT, 'ip', 'kosmo2_m9_top', 'sim', 'vec_full')
F_MC = 31
F_MCB = 24
MC_IDENT = 1 << F_MCB

os.makedirs(OUT_DIR, exist_ok=True)


# ------------------------------------------------------------------ integer chain
def conv_gold_f64(x, w, b):
    """x: (IC,H,W) int64; w: (OC,IC,3,3) int8; b: (OC,) int32 -> (OC,H,W) int64"""
    ic, h, wd = x.shape
    oc = w.shape[0]
    xp = np.pad(x.astype(np.float64), ((0, 0), (1, 1), (1, 1)))
    acc = np.zeros((oc, h, wd), dtype=np.float64)
    for ky in range(3):
        for kw in range(3):
            acc += np.tensordot(w[:, :, ky, kw].astype(np.float64),
                                xp[:, ky:ky + h, kw:kw + wd], axes=([1], [0]))
    acc += b.astype(np.float64)[:, None, None]
    # 精确整数结果 -> int64
    return np.rint(acc).astype(np.int64)


def req_pre(acc, mc):
    q = (acc * mc[:, None, None] + (1 << (F_MC - 1))) >> F_MC
    return np.clip(q, -128, 127)


def pool2x2(a):
    c, h, w = a.shape
    assert h % 2 == 0 and w % 2 == 0
    return a.reshape(c, h // 2, 2, w // 2, 2).max(axis=(2, 4))


def req_boundary(a, mc):
    q = (a * int(mc) + (1 << (F_MCB - 1))) >> F_MCB
    return np.clip(q, -128, 127)


def emit_beats(path, arr, what):
    flat = np.asarray(arr, dtype=np.int64).reshape(-1)
    assert flat.size % 16 == 0, (what, flat.size)
    nbeats = flat.size // 16
    buf = []
    for i in range(nbeats):
        v = 0
        for j in range(16):
            v |= (int(flat[i * 16 + j]) & 0xFF) << (8 * j)
        buf.append('%032x' % v)
    open(path, 'w', newline='\n').write('\n'.join(buf) + '\n')
    crc = zlib.crc32(bytes((int(v) & 0xFF) for v in flat)) & 0xFFFFFFFF
    print('[ok] %-22s %8d B  %6d beats  crc32=%08x' % (what, flat.size, nbeats, crc))
    return int(flat.size), nbeats, crc


# ------------------------------------------------------------------ inputs
qp = json.load(open(os.path.join(QE, 'quant_params.json'), encoding='utf-8'))
mf = json.load(open(os.path.join(TV, 'manifest.json'), encoding='utf-8'))
spec = json.load(open(os.path.join(QE, 'fpga_architecture_spec.json'), encoding='utf-8'))
layers = qp['conv_layers']
lt = mf['layers_table']
N = len(layers)
assert N == 10 and len(lt) == 10

# 满尺寸 shape：每层卷积输出 = 该层输入（stride1/pad1）
full_hw = []
h0, w0 = spec['input']['input_hw']
ch, cw = h0, w0
for k, L in enumerate(spec['layers']):
    hh, ww = L['out_hw']
    assert (hh, ww) == (ch, cw), (k, hh, ww, ch, cw)
    full_hw.append((hh, ww))
    ch = hh // 2 if lt[k]['pool_after'] else hh
    cw = ww // 2 if lt[k]['pool_after'] else ww
assert full_hw[0] == (480, 1024) and full_hw[-1] == (30, 64)
assert (ch, cw) == (15, 32)

# 每层 Mc/McB（与 gen_m8_cfg.py 同公式）
mc_all, mcb_all, bnd_all, w_all, b_all = [], [], [], [], []
for k, L in enumerate(layers):
    sw = np.asarray(L['weight_scale'], dtype=np.float64)
    mc = np.round(L['act_in_scale'] * sw / L['act_out_scale'] * 2.0 ** F_MC).astype(np.int64)
    assert mc.min() > 0 and mc.max() < (1 << 31)
    ratio = lt[k]['boundary_ratio_to_next']
    if ratio is None or abs(ratio - 1.0) < 1e-12:
        mcb, bnd = MC_IDENT, 0
    else:
        mcb, bnd = int(round(ratio * (1 << F_MCB))), 1
        assert 0 < mcb < (1 << 31)
    mc_all.append(mc)
    mcb_all.append(mcb)
    bnd_all.append(bnd)
    w_all.append(np.load(os.path.join(QE, 'weights_int8', L['name'] + '_w_int8.npy')))
    b_all.append(np.load(os.path.join(QE, 'weights_int8', L['name'] + '_b_int32.npy')))

# 核对真实配置 ROM 与生成器口径一致
cfg_rows = [int(s, 16) for s in open(CFG_MEM, encoding='utf-8').read().split()]
assert len(cfg_rows) == 10, len(cfg_rows)
for k, v in enumerate(cfg_rows):
    in_ch = (v >> 0) & 0x7F
    out_ch = (v >> 7) & 0x7F
    hh = (v >> 14) & 0x7FF
    ww = (v >> 25) & 0x7FF
    relu = (v >> 40) & 1
    pool = (v >> 41) & 1
    bnd = (v >> 42) & 1
    mcb = (v >> 48) & 0xFFFFFFFF
    assert (in_ch, out_ch) == (w_all[k].shape[1], w_all[k].shape[0]), (k, in_ch, out_ch, w_all[k].shape)
    assert (hh, ww) == full_hw[k], (k, (hh, ww), full_hw[k])
    assert relu == int(lt[k]['relu_after']), (k, 'relu', relu)
    assert pool == int(lt[k]['pool_after']), (k, 'pool', pool)
    assert bnd == bnd_all[k] and mcb == mcb_all[k], (k, 'bnd/mcb', bnd, mcb, bnd_all[k], mcb_all[k])
    print('L%d %-6s %2d->%2d %4dx%-4d bank=%d relu=%d pool=%d bnd=%d McB=%9d'
          % (k, layers[k]['name'], in_ch, out_ch, hh, ww, (v >> 36) & 0xF,
             relu, pool, bnd, mcb))

x = np.load(os.path.join(SMP, 'conv00_in_int8.npy')).reshape(3, 480, 1024).astype(np.int64)
assert x.shape == (3, 480, 1024)
n_in, n_in_beats, crc_in = emit_beats(os.path.join(OUT_DIR, 'm9_full_in_beats.hex'), x, 'input')

# ------------------------------------------------------------------ golden chain
t0 = time.time()
for k in range(N):
    ts = time.time()
    acc = conv_gold_f64(x, w_all[k], b_all[k])
    q = req_pre(acc, mc_all[k])
    del acc
    q = np.maximum(q, 0)
    if lt[k]['pool_after']:
        q = pool2x2(q)
    if bnd_all[k]:
        q = req_boundary(q, mcb_all[k])
    x = q
    print('L%d %-6s out %s  %.1fs' % (k, layers[k]['name'], x.shape, time.time() - ts))
final = x
assert final.shape == (96, 15, 32), final.shape
assert final.min() >= 0
n_out, n_out_beats, crc_out = emit_beats(
    os.path.join(OUT_DIR, 'm9_full_exp_beats.hex'), final, 'final exp')

manifest = {
    'generator': 'tools/gen_m9_full_vec.py',
    'source_quant_export': QE,
    'source_test_vectors': TV,
    'source_sample': os.path.basename(SMP),
    'formula': {
        'conv': 'acc = sum(x*w)+bias (int8, int64)',
        'requant_pre': 'clamp((acc*Mc + 2^30)>>31, -128,127), then ReLU',
        'boundary': 'pool2x2 then clamp((q*McB + 2^23)>>24, -128,127)',
        'f_mc': F_MC, 'f_mcb': F_MCB, 'mc_identity': MC_IDENT,
    },
    'layers': [{
        'layer': layers[k]['name'], 'in_ch': int(w_all[k].shape[1]),
        'out_ch': int(w_all[k].shape[0]), 'hw': list(full_hw[k]),
        'relu': int(lt[k]['relu_after']), 'pool': int(lt[k]['pool_after']),
        'bnd': int(bnd_all[k]), 'McB': int(mcb_all[k]),
    } for k in range(N)],
    'vectors': {
        'm9_full_in_beats.hex': {'bytes': n_in, 'beats': n_in_beats, 'crc32': crc_in},
        'm9_full_exp_beats.hex': {'bytes': n_out, 'beats': n_out_beats, 'crc32': crc_out},
    },
    'golden_time_s': round(time.time() - t0, 1),
}
open(os.path.join(OUT_DIR, 'manifest.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('[ok] vectors -> %s' % OUT_DIR)
print('[ok] final shape %s  in=%d B  out=%d B  golden %.1fs'
      % (final.shape, n_in, n_out, time.time() - t0))
