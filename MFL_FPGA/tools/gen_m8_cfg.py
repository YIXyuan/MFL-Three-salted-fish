# -*- coding: utf-8 -*-
"""
gen_m8_cfg.py -- M8 ctrl_fsm 层配置 ROM + 缩放链路联仿向量生成器（禁止手抄）

输入（唯一来源）:
  quant_export/quant_params.json                每层 in/out_ch、act_in/out_scale、weight_scale
  quant_export/fpga_architecture_spec.json     逐层 out_hw（= 该层卷积输出/下一层输入尺寸）
  test_vectors/manifest.json                   layers_table: relu_after/pool_after/ratio
  test_vectors/sample_0_Train_A_0000053/conv00_in_int8.npy   缩放链路输入 crop

输出:
  ip/kosmo2_ctrl_fsm/mem/layer_cfg.mem          真实 10 层配置（480x1024 起）, 128bit x10
  ip/kosmo2_ctrl_fsm/mem/manifest.json          字段解码/Mc/McB/尺寸/缓冲选择/CRC
  ip/kosmo2_ctrl_fsm/sim/vec/layer_cfg_test.hex 缩放 10 层配置（32x512 起, 同样通道/池化/比例）
  ip/kosmo2_ctrl_fsm/sim/vec/m8_in.hex          测试输入 crop（3x32x512, 每行 1 字节）
  ip/kosmo2_ctrl_fsm/sim/vec/m8_conv00_exp.hex  conv00 post-ReLU 原始输出（16x32x512）
  ip/kosmo2_ctrl_fsm/sim/vec/m8_final_exp.hex   全链最终特征图（96x1x16, pool 后）

配置字布局（128bit）:
  [6:0] in_ch | [13:7] out_ch | [24:14] H | [35:25] W | [39:36] w_bank
  [40] relu | [41] pool | [42] bnd | [47:43] fshift_b | [79:48] McB
  [81:80] in_sel | [83:82] out_sel | [85:84] bnd_out_sel
  in_sel: 0=REBUF_A 1=REBUF_B 2=IN_ADDR 3=OUT_ADDR ; out_sel: 0=A 1=B
  bnd_out_sel: 0=A 1=B 3=OUT_ADDR（M8 在 k==layer_end 时强制 OUT）

口径:
  conv:  acc = sum(x*w) + bias
  第一级: q = clamp((acc*Mc + 2^30) >> 31, -128,127), 再 ReLU（10 层全 1）
  边界:   pool(2x2s2, signed max) 后 q2 = clamp((q*McB + 2^23) >> 24, -128,127)
          ratio==1 免换挡（硬件用 Mc=2^24 的恒等 requant）
"""
import json
import os
import zlib

import numpy as np

ROOT = r'C:\Users\21889\Desktop\Kosmo2_MES2K100'
QE = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
TV = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors'
SMP = os.path.join(TV, 'sample_0_Train_A_0000053')
MEM = os.path.join(ROOT, 'ip', 'kosmo2_ctrl_fsm', 'mem')
VEC = os.path.join(ROOT, 'ip', 'kosmo2_ctrl_fsm', 'sim', 'vec')
F_MC = 31
F_MCB = 24
MC_IDENT = 1 << F_MCB

os.makedirs(MEM, exist_ok=True)
os.makedirs(VEC, exist_ok=True)

qp = json.load(open(os.path.join(QE, 'quant_params.json'), encoding='utf-8'))
mf = json.load(open(os.path.join(TV, 'manifest.json'), encoding='utf-8'))
spec = json.load(open(os.path.join(QE, 'fpga_architecture_spec.json'), encoding='utf-8'))
layers = qp['conv_layers']
lt = mf['layers_table']
N = len(layers)
assert N == 10 and len(lt) == 10


# ------------------------------------------------------------------ helpers
def pack_cfg(in_ch, out_ch, h, w, bank, relu, pool, bnd, fshift_b, mc,
             in_sel, out_sel, bnd_out):
    v = 0
    v |= (in_ch & 0x7F)
    v |= (out_ch & 0x7F) << 7
    v |= (h & 0x7FF) << 14
    v |= (w & 0x7FF) << 25
    v |= (bank & 0xF) << 36
    v |= (relu & 1) << 40
    v |= (pool & 1) << 41
    v |= (bnd & 1) << 42
    v |= (fshift_b & 0x1F) << 43
    v |= (mc & 0xFFFFFFFF) << 48
    v |= (in_sel & 0x3) << 80
    v |= (out_sel & 0x3) << 82
    v |= (bnd_out & 0x3) << 84
    return v


def emit_cfg(path, rows):
    open(path, 'w', newline='\n').write(
        '\n'.join('%032x' % v for v in rows) + '\n')


def conv_gold(x, w, b):
    ic, h, wd = x.shape
    oc = w.shape[0]
    xp = np.pad(x.astype(np.int64), ((0, 0), (1, 1), (1, 1)))
    acc = np.zeros((oc, h, wd), dtype=np.int64)
    for ky in range(3):
        for kw in range(3):
            acc += np.tensordot(w[:, :, ky, kw].astype(np.int64),
                                xp[:, ky:ky + h, kw:kw + wd], axes=([1], [0]))
    return acc + b.astype(np.int64)[:, None, None]


def pool2x2(a):
    c, h, w = a.shape
    return a.reshape(c, h // 2, 2, w // 2, 2).max(axis=(2, 4))


def req(acc, mc):
    q = (acc.astype(np.int64) * mc[:, None, None] + (1 << (F_MC - 1))) >> F_MC
    return np.maximum(np.clip(q, -128, 127), 0)


def req_pre(acc, mc):
    """第一级 requant 但**不做 ReLU**（pre-ReLU 导出基准）"""
    return np.clip((acc.astype(np.int64) * mc[:, None, None] + (1 << (F_MC - 1))) >> F_MC,
                   -128, 127)


def req_boundary(a, mc):
    q = (a.astype(np.int64) * int(mc) + (1 << (F_MCB - 1))) >> F_MCB
    return np.clip(q, -128, 127).astype(np.int64)


def emit_bytes(path, arr):
    flat = np.asarray(arr, dtype=np.int64).reshape(-1)
    open(path, 'w', newline='\n').write(
        '\n'.join('%02x' % (int(v) & 0xFF) for v in flat) + '\n')
    return zlib.crc32(bytes([int(v) & 0xFF for v in flat])) & 0xFFFFFFFF


# ------------------------------------------------------------------ layer descriptors
# 真实尺寸: spec.layers[k].out_hw 是该层卷积输出（= 该层输入尺寸, stride1/pad1）
full_hw = []
h0, w0 = spec['input']['input_hw']
ch, cw = h0, w0
for k, L in enumerate(spec['layers']):
    hh, ww = L['out_hw']
    assert (hh, ww) == (ch, cw), (k, hh, ww, ch, cw)
    full_hw.append((hh, ww))
    ch = hh // 2 if lt[k]['pool_after'] else hh
    cw = ww // 2 if lt[k]['pool_after'] else ww
assert full_hw[-1] == (30, 64) and (ch, cw) == (15, 32)

# 缩放测试尺寸: 32x512 起 -> 5 次池化 -> 1x16（W 始终 >=16 且为 16 的倍数）
test_hw = []
th, tw = 32, 512
for k in range(N):
    test_hw.append((th, tw))
    if lt[k]['pool_after']:
        assert th % 2 == 0 and tw % 2 == 0
        th, tw = th // 2, tw // 2
assert test_hw[-1] == (2, 32) and (1, 16) == (test_hw[-1][0] // 2, test_hw[-1][1] // 2)

# 每层 Mc / McB
w_all, b_all, mc_all, mcb_all = [], [], [], []
for k, L in enumerate(layers):
    sw = np.asarray(L['weight_scale'], dtype=np.float64)
    mc = np.round(L['act_in_scale'] * sw / L['act_out_scale'] * 2.0 ** F_MC).astype(np.int64)
    assert mc.min() > 0 and mc.max() < (1 << 31)
    ratio = lt[k]['boundary_ratio_to_next']
    if ratio is None or abs(ratio - 1.0) < 1e-12:
        mcb = MC_IDENT
        bnd = 0
    else:
        mcb = int(round(ratio * (1 << F_MCB)))
        assert 0 < mcb < (1 << 31)
        bnd = 1
    mc_all.append(mc)
    mcb_all.append(mcb)
    w_all.append(np.load(os.path.join(QE, 'weights_int8', L['name'] + '_w_int8.npy')))
    b_all.append(np.load(os.path.join(QE, 'weights_int8', L['name'] + '_b_int32.npy')))
    assert int(mcb) == (lt[k].get('McB') or mcb), (k, mcb, lt[k].get('McB'))

# ------------------------------------------------------------------ buffer plan
def plan(n):
    """返回每层 in_sel/out_sel/bnd_out_sel; 0=A 1=B 2=IN 3=OUT"""
    cur, free = 2, 0
    rows = []
    for k in range(n):
        in_sel, out_sel = cur, free
        if k == n - 1:
            bnd_out = 3
            next_cur = 3
        elif lt[k]['pool_after'] or mcb_all[k] != MC_IDENT:
            bnd_out = 0 if out_sel == 1 else 1
            next_cur = bnd_out
        else:
            bnd_out = 0                      # don't care
            next_cur = out_sel
        rows.append((in_sel, out_sel, bnd_out))
        cur = next_cur
        if cur == 0:
            free = 1
        elif cur == 1:
            free = 0
        else:
            free = 0                         # last layer, no next
    return rows

bplan = plan(N)

full_cfg, test_cfg = [], []
for k in range(N):
    L = layers[k]
    # ONNX (OC, IC, 3, 3)
    oc, ic = int(L['w_shape'][0]), int(L['w_shape'][1])
    in_sel, out_sel, bnd_out = bplan[k]
    pool = 1 if lt[k]['pool_after'] else 0
    bnd = 0 if mcb_all[k] == MC_IDENT else 1
    relu = 1 if lt[k]['relu_after'] else 0
    hh, ww = full_hw[k]
    full_cfg.append(pack_cfg(ic, oc, hh, ww, k, relu, pool, bnd,
                             F_MCB, mcb_all[k], in_sel, out_sel, bnd_out))
    th, tw = test_hw[k]
    test_cfg.append(pack_cfg(ic, oc, th, tw, k, relu, pool, bnd,
                             F_MCB, mcb_all[k], in_sel, out_sel, bnd_out))
    print('L%d %-6s %2d->%2d full %4dx%-4d test %3dx%-3d bank=%d relu=%d pool=%d bnd=%d '
          'McB=%9d sel(in/out/bnd)=%d/%d/%d'
          % (k, L['name'], ic, oc, hh, ww, th, tw, k, relu, pool, bnd,
             mcb_all[k] if bnd else MC_IDENT, in_sel, out_sel, bnd_out))

emit_cfg(os.path.join(MEM, 'layer_cfg.mem'), full_cfg)
emit_cfg(os.path.join(VEC, 'layer_cfg_test.hex'), test_cfg)

# ------------------------------------------------------------------ test chain gold
crop = np.load(os.path.join(SMP, 'conv00_in_int8.npy'))[0][:, 0:32, 0:512].astype(np.int64)
assert crop.shape == (3, 32, 512)
crc_in = emit_bytes(os.path.join(VEC, 'm8_in.hex'), crop)

x = crop
conv00_exp = None
conv00_pre = None
conv01_pre = None
l1_bnd = None
for k in range(N):
    acc = conv_gold(x, w_all[k], b_all[k])
    q_pre = req_pre(acc, mc_all[k])
    q = np.maximum(q_pre, 0)
    if k == 0:
        conv00_exp = q.copy()
        conv00_pre = q_pre.copy()
        # 与真实全图 conv00 输出对比（真实向量是 pre-ReLU, 硬件 q 已 ReLU -> 先取 max(ref,0)）
        real = np.load(os.path.join(SMP, 'conv00_out_int8.npy'))[0][:, 0:31, 0:511].astype(np.int64)
        got = q[:, 0:31, 0:511]
        d = got - np.maximum(real, 0)
        print('conv00 crop sanity vs real sample: exact=%.2f%% |d|<=1=%.2f%% max=%d'
              % (100 * (d == 0).mean(), 100 * (np.abs(d) <= 1).mean(), np.abs(d).max()))
    if k == 1:
        conv01_pre = q_pre.copy()
    if lt[k]['pool_after']:
        q = pool2x2(q)
    if mcb_all[k] != MC_IDENT:
        q = req_boundary(q, mcb_all[k])
    if k == 1:
        l1_bnd = q.copy()          # 停层 LAYER=1 的边界处理后输出（= 层 2 输入口径）
    x = q
final_exp = x.astype(np.int64)
assert final_exp.shape == (96, 1, 16), final_exp.shape
assert final_exp.min() >= 0
assert conv00_pre.shape == (16, 32, 512) and conv01_pre.shape == (16, 32, 512)
assert l1_bnd.shape == (16, 16, 256)

crc_c0 = emit_bytes(os.path.join(VEC, 'm8_conv00_exp.hex'), conv00_exp)
crc_c0pre = emit_bytes(os.path.join(VEC, 'm8_conv00_prerelu_exp.hex'), conv00_pre)
crc_c1pre = emit_bytes(os.path.join(VEC, 'm8_conv01_prerelu_exp.hex'), conv01_pre)
crc_l1b = emit_bytes(os.path.join(VEC, 'm8_l1_bnd_exp.hex'), l1_bnd)
crc_fin = emit_bytes(os.path.join(VEC, 'm8_final_exp.hex'), final_exp)
print('conv00_exp %s  conv00_pre %s  conv01_pre %s  l1_bnd %s  final_exp %s'
      % (conv00_exp.shape, conv00_pre.shape, conv01_pre.shape, l1_bnd.shape, final_exp.shape))

# ------------------------------------------------------------------ manifest
manifest = {
    'generator': 'tools/gen_m8_cfg.py',
    'source_quant_export': QE,
    'source_test_vectors': TV,
    'config_layout': {
        'in_ch': '[6:0]', 'out_ch': '[13:7]', 'H': '[24:14]', 'W': '[35:25]',
        'w_bank': '[39:36]', 'relu': '[40]', 'pool': '[41]', 'bnd': '[42]',
        'fshift_b': '[47:43]', 'McB': '[79:48]', 'in_sel': '[81:80]',
        'out_sel': '[83:82]', 'bnd_out_sel': '[85:84]',
        'sel': {'0': 'REBUF_A', '1': 'REBUF_B', '2': 'IN_ADDR', '3': 'OUT_ADDR'},
    },
    'f_mc': F_MC, 'f_mcb': F_MCB, 'mc_identity': MC_IDENT,
    'full_config_file': 'layer_cfg.mem',
    'test_config_file': 'sim/vec/layer_cfg_test.hex',
    'test_start_hw': [32, 512],
    'test_final_hw': [1, 16],
    'layers': [{
        'layer': layers[k]['name'], 'index': k,
        'in_ch': int(layers[k]['w_shape'][1]), 'out_ch': int(layers[k]['w_shape'][0]),
        'full_hw': list(full_hw[k]), 'test_hw': list(test_hw[k]),
        'w_bank': k, 'relu': int(lt[k]['relu_after']), 'pool': int(lt[k]['pool_after']),
        'bnd': 0 if mcb_all[k] == MC_IDENT else 1, 'McB': int(mcb_all[k]),
        'ratio': lt[k]['boundary_ratio_to_next'],
        'in_sel': bplan[k][0], 'out_sel': bplan[k][1], 'bnd_out_sel': bplan[k][2],
        'Mc': [int(v) for v in mc_all[k]],
    } for k in range(N)],
    'test_vectors': {
        'm8_in.hex': {'bytes': int(crop.size), 'crc32': crc_in},
        'm8_conv00_exp.hex': {'bytes': int(conv00_exp.size), 'crc32': crc_c0},
        'm8_conv00_prerelu_exp.hex': {'bytes': int(conv00_pre.size), 'crc32': crc_c0pre},
        'm8_conv01_prerelu_exp.hex': {'bytes': int(conv01_pre.size), 'crc32': crc_c1pre},
        'm8_l1_bnd_exp.hex': {'bytes': int(l1_bnd.size), 'crc32': crc_l1b},
        'm8_final_exp.hex': {'bytes': int(final_exp.size), 'crc32': crc_fin},
    },
}
open(os.path.join(MEM, 'manifest.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

print('[ok] cfg  -> %s' % os.path.join(MEM, 'layer_cfg.mem'))
print('[ok] vec  -> %s' % VEC)
