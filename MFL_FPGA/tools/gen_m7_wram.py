# -*- coding: utf-8 -*-
"""
gen_m7_wram.py -- M7 wram_bank 参数仓库生成器（唯一合法来源，禁止手抄）

输入（v2 quant_export，HANDOFF §5.1 唯一来源）:
  quant_export/quant_params.json
  quant_export/weights_int8/convXX_w_int8.npy   (OC, IC, 3, 3) int8, BN 已折叠
  quant_export/weights_int8/convXX_b_int32.npy  (OC,) int32
  test_vectors/sample_0.../convXX_in_int8.npy   (联仿用真实 patch)

输出:
  ip/kosmo2_wram_bank/mem/convXX_w.mem    权重列 ROM, 深度 9*IC, 每行 OC*8 bit
                                          列号 t=(ky*3+kw)*IC+cin, 字节 lane c=输出通道
  ip/kosmo2_wram_bank/mem/convXX_b.mem    偏置整行, 1 行 OC*32 bit (lane c 在 32c)
  ip/kosmo2_wram_bank/mem/convXX_mc.mem   Mc 整行, 同上
  ip/kosmo2_wram_bank/mem/convXX_crc.hex  CRC32 三行: w / bias / Mc（解码字节流）
  ip/kosmo2_wram_bank/mem/convXX_spot.hex 16 条抽查 {t[15:0],c[7:0],v[7:0]}
  ip/kosmo2_wram_bank/mem/manifest.json   深度/宽度/CRC/源文件 sha256/公式
  ip/kosmo2_wram_bank/sim/vec/joint{0,1}_*.hex  M6+M7 联仿 patch 输入/期望

自校验（任一失败即抛异常, 不产出半成品）:
  1) 列排布逆变换回 (OC,IC,3,3) 与 npy 逐字节相等
  2) 重新解析 .mem 文件解码, 与内存列数组逐字节相等
  3) 每行位宽/行数断言; 高位补零断言
  4) CRC32 用 zlib（与 TB 的反射多项式实现一致）
口径: Mc[c] = round(act_in * weight_scale[c] / act_out * 2^31)  (int32)
      requant: q = clamp((acc*Mc + 2^30) >> 31, -128, 127), 再 ReLU
"""
import hashlib
import json
import os
import zlib

import numpy as np

ROOT = r'C:\Users\21889\Desktop\Kosmo2_MES2K100'
QE = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
TV = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors'
SMP = os.path.join(TV, 'sample_0_Train_A_0000053')
MEM = os.path.join(ROOT, 'ip', 'kosmo2_wram_bank', 'mem')
VEC = os.path.join(ROOT, 'ip', 'kosmo2_wram_bank', 'sim', 'vec')
F_MC = 31

os.makedirs(MEM, exist_ok=True)
os.makedirs(VEC, exist_ok=True)

qp = json.load(open(os.path.join(QE, 'quant_params.json'), encoding='utf-8'))
layers = qp['conv_layers']
assert len(layers) == 10, 'expect 10 conv layers'


# ---------------------------------------------------------------- helpers
def hexline(value, nbits):
    """value -> 定宽 hex（左补零）, 位宽 nbits"""
    nhex = (nbits + 3) // 4
    assert 0 <= value < (1 << nbits), 'value %x does not fit %d bits' % (value, nbits)
    return format(value, '0%dx' % nhex)


def wcol_array(w):
    """(OC,IC,3,3) int8 -> (9*IC, OC) int64, t=(ky*3+kw)*IC+cin"""
    oc, ic = w.shape[0], w.shape[1]
    cols = np.zeros((9 * ic, oc), dtype=np.int64)
    for ky in range(3):
        for kw in range(3):
            for cin in range(ic):
                t = (ky * 3 + kw) * ic + cin
                cols[t, :] = w[:, cin, ky, kw].astype(np.int64)
    return cols


def inverse_wcol(cols, oc, ic):
    """(9*IC,OC) -> (OC,IC,3,3), 独立逆变换（自校验用）"""
    w = np.zeros((oc, ic, 3, 3), dtype=np.int64)
    for ky in range(3):
        for kw in range(3):
            for cin in range(ic):
                t = (ky * 3 + kw) * ic + cin
                w[:, cin, ky, kw] = cols[t, :]
    return w


def crc32_bytes(buf):
    return zlib.crc32(buf) & 0xFFFFFFFF


def crc_stream(words, width_bits):
    """按 ROM 解码字节流计算 CRC: 字 0..n-1, 每字字节 lane 升序（小端）"""
    nbytes = width_bits // 8
    buf = bytearray()
    for v in words:
        for b in range(nbytes):
            buf.append((int(v) >> (8 * b)) & 0xFF)
    return crc32_bytes(bytes(buf)), bytes(buf)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- per layer
meta_layers = []
const_rows = []          # (li, oc, bias_word, mc_word) -> RTL 常量模块
for li, L in enumerate(layers):
    name = L['name']
    w = np.load(os.path.join(QE, 'weights_int8', name + '_w_int8.npy'))
    b = np.load(os.path.join(QE, 'weights_int8', name + '_b_int32.npy'))
    assert w.ndim == 4 and w.shape[2:] == (3, 3), (name, w.shape)
    oc, ic = int(w.shape[0]), int(w.shape[1])
    assert b.shape == (oc,), (name, b.shape)
    assert oc <= 96 and ic <= 96
    depth = 9 * ic

    sw = np.asarray(L['weight_scale'], dtype=np.float64)
    assert sw.shape == (oc,)
    mc64 = np.round(L['act_in_scale'] * sw / L['act_out_scale'] * (2.0 ** F_MC)).astype(np.int64)
    assert mc64.min() > 0 and mc64.max() < (1 << 31), (name, mc64.min(), mc64.max())
    mc = mc64.astype(np.int64)

    # --- 列排布 ---
    cols = wcol_array(w)
    assert cols.shape == (depth, oc)
    rec = inverse_wcol(cols, oc, ic)
    if not np.array_equal(rec, w.astype(np.int64)):
        raise AssertionError('%s: column layout inverse mismatch' % name)

    # --- 权重 .mem ---
    wlines = []
    wwords = []
    for t in range(depth):
        v = 0
        for c in range(oc):
            v |= (int(cols[t, c]) & 0xFF) << (8 * c)
        wwords.append(v)
        wlines.append(hexline(v, oc * 8))
    wpath = os.path.join(MEM, name + '_w.mem')
    open(wpath, 'w', newline='\n').write('\n'.join(wlines) + '\n')

    # --- bias / Mc 整行 .mem ---
    bwords = []
    blines = []
    for c in range(oc):
        v = int(b[c]) & 0xFFFFFFFF
        bwords.append(v)
        blines.append(hexline(v, 32))
    # 单行宽字
    bword = 0
    for c in range(oc):
        bword |= (int(b[c]) & 0xFFFFFFFF) << (32 * c)
    open(os.path.join(MEM, name + '_b.mem'), 'w', newline='\n').write(
        hexline(bword, oc * 32) + '\n')

    mword = 0
    for c in range(oc):
        mword |= (int(mc[c]) & 0xFFFFFFFF) << (32 * c)
    open(os.path.join(MEM, name + '_mc.mem'), 'w', newline='\n').write(
        hexline(mword, oc * 32) + '\n')

    # --- CRC (解码字节流, 与 TB 同序) ---
    crc_w, _ = crc_stream(wwords, oc * 8)
    crc_b, _ = crc_stream(bwords, 32)
    crc_m, _ = crc_stream([int(v) & 0xFFFFFFFF for v in mc], 32)
    open(os.path.join(MEM, name + '_crc.hex'), 'w', newline='\n').write(
        '%08x\n%08x\n%08x\n' % (crc_w, crc_b, crc_m))

    # --- 抽查（直接按 npy 原始下标取, 独立于列变换） ---
    rng = np.random.default_rng(0x4D370000 + li)
    spots = []
    seen = set()
    while len(spots) < 16:
        c = int(rng.integers(0, oc))
        t = int(rng.integers(0, depth))
        if (c, t) in seen:
            continue
        seen.add((c, t))
        cin = t % ic
        kk = t // ic
        ky, kw = kk // 3, kk % 3
        v = int(w[c, cin, ky, kw]) & 0xFF
        # 断言与列数组一致（两条独立路径）
        assert (int(cols[t, c]) & 0xFF) == v
        spots.append((t << 16) | (c << 8) | v)
    open(os.path.join(MEM, name + '_spot.hex'), 'w', newline='\n').write(
        '\n'.join('%08x' % v for v in spots) + '\n')

    # --- 重新解析 .mem 自校验 ---
    got_lines = open(wpath, encoding='ascii').read().split()
    assert len(got_lines) == depth, (name, 'w.mem lines', len(got_lines), depth)
    nhex = (oc * 8 + 3) // 4
    for t, line in enumerate(got_lines):
        assert len(line) == nhex, (name, t, len(line), nhex)
        v = int(line, 16)
        for c in range(oc):
            if ((v >> (8 * c)) & 0xFF) != (int(cols[t, c]) & 0xFF):
                raise AssertionError('%s: mem decode mismatch t=%d c=%d' % (name, t, c))
        # 行内没有 out_ch 之外的 lane（位宽天然保证）

    bl = open(os.path.join(MEM, name + '_b.mem'), encoding='ascii').read().split()
    ml = open(os.path.join(MEM, name + '_mc.mem'), encoding='ascii').read().split()
    assert len(bl) == 1 and len(ml) == 1
    assert len(bl[0]) == (oc * 32 + 3) // 4 and len(ml[0]) == (oc * 32 + 3) // 4
    bv = int(bl[0], 16)
    mv = int(ml[0], 16)
    for c in range(oc):
        assert ((bv >> (32 * c)) & 0xFFFFFFFF) == (int(b[c]) & 0xFFFFFFFF), (name, 'bias', c)
        assert ((mv >> (32 * c)) & 0xFFFFFFFF) == (int(mc[c]) & 0xFFFFFFFF), (name, 'mc', c)
    # 高位补零：整行之外不存在（单行位宽就是 OC*32）

    const_rows.append((li, oc, bword, mword))
    meta_layers.append({
        'layer': name, 'index': li, 'in_ch': ic, 'out_ch': oc,
        'depth': depth, 'w_bits': oc * 8, 'b_bits': oc * 32, 'mc_bits': oc * 32,
        'w_file': name + '_w.mem', 'b_file': name + '_b.mem', 'mc_file': name + '_mc.mem',
        'crc32_w': crc_w, 'crc32_b': crc_b, 'crc32_mc': crc_m,
        'w_file_sha256': sha256_file(wpath),
        'w_src_sha256': sha256_file(os.path.join(QE, 'weights_int8', name + '_w_int8.npy')),
        'b_src_sha256': sha256_file(os.path.join(QE, 'weights_int8', name + '_b_int32.npy')),
        'mc_min': int(mc.min()), 'mc_max': int(mc.max()),
        'bias_min': int(b.min()), 'bias_max': int(b.max()),
        'act_in_scale': L['act_in_scale'], 'act_out_scale': L['act_out_scale'],
        'mc_formula': 'round(act_in*weight_scale[c]/act_out*2^31)',
        'f_mc': F_MC,
        'spot_count': len(spots),
    })
    print('%-7s IC=%2d OC=%2d depth=%3d  w=%3db/%2dB  Mc[%d..%d]  crc w=%08x b=%08x m=%08x'
          % (name, ic, oc, depth, oc * 8, oc, int(mc.min()), int(mc.max()),
             crc_w, crc_b, crc_m))

manifest = {
    'generator': 'tools/gen_m7_wram.py',
    'source_quant_export': QE,
    'source_test_vectors': TV,
    'f_mc': F_MC,
    'note': 'columns t=(ky*3+kw)*IC+cin; byte lane c = output channel; high lanes zero',
    'crc': 'CRC-32/ISO-HDLC over decoded ROM byte stream: word 0..n-1, byte lane 0.. up',
    'layers': meta_layers,
}
open(os.path.join(MEM, 'manifest.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

# ---------------------------------------------------------------- RTL const module
# PDS(ADS) 不支持“常量地址读”的 $readmemh ROM（bias/Mc 会被展平成无驱动网络），
# 因此 bias/Mc 整行直接生成为 RTL 常量，权重仍用 $readmemh（PDS 能正常推断 BRAM）。
const_path = os.path.join(ROOT, 'ip', 'kosmo2_wram_bank', 'rtl',
                          'kosmo2_wram_bank_const_v1_0.v')
cl = []
cl.append('// -----------------------------------------------------------------------------')
cl.append('// GENERATED by tools/gen_m7_wram.py -- do not edit')
cl.append('// bias/Mc whole rows as RTL constants (one per bank, native out_ch*32 width).')
cl.append('// PDS cannot initialize a constant-address ROM via $readmemh, so bias/Mc are')
cl.append('// emitted as constants; weight columns remain $readmemh ROMs.')
cl.append('// -----------------------------------------------------------------------------')
cl.append('`timescale 1ns / 1ps')
cl.append('')
cl.append('module kosmo2_wram_bank_const_v1_0 (')
port_lines = []
for li, oc, _, _ in const_rows:
    port_lines.append('    output wire [%d:0] %s' % (oc * 32 - 1, 'bias%d, mc%d,' % (li, li)))
cl.extend(port_lines)
# 最后一个端口行去掉尾部逗号
cl[-1] = cl[-1][:-1]
cl.append(');')
cl.append('')
for li, oc, bword, mword in const_rows:
    nhex = oc * 8
    cl.append("    assign bias%d = %d'h%s;" % (li, oc * 32, format(bword, '0%dx' % nhex)))
    cl.append("    assign mc%d   = %d'h%s;" % (li, oc * 32, format(mword, '0%dx' % nhex)))
cl.append('')
cl.append('endmodule')
open(const_path, 'w', newline='\n').write('\n'.join(cl) + '\n')
print('[ok] const RTL -> %s' % const_path)


# ---------------------------------------------------------------- joint M6 vectors
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


def emit_in(path, x):
    """每行 16 字节(128bit), 次序 (c,y,beat); 行内 x=beat*16+j 从最高字节起"""
    ic, h, wd = x.shape
    assert wd % 16 == 0, wd
    lines = []
    for c in range(ic):
        for y in range(h):
            row = x[c, y]
            for b in range(wd // 16):
                lines.append(''.join('%02x' % (int(row[b * 16 + j]) & 0xFF)
                                     for j in range(16)))
    open(path, 'w', newline='\n').write('\n'.join(lines) + '\n')


def emit_exp(path, q):
    oc, h, wd = q.shape
    lines = []
    for c in range(oc):
        for y in range(h):
            for x in range(wd):
                lines.append('%02x' % (int(q[c, y, x]) & 0xFF))
    open(path, 'w', newline='\n').write('\n'.join(lines) + '\n')


def make_joint(tag, li, r0, c0, wd=16, ht=6):
    L = layers[li]
    name = L['name']
    w = np.load(os.path.join(QE, 'weights_int8', name + '_w_int8.npy')).astype(np.int64)
    b = np.load(os.path.join(QE, 'weights_int8', name + '_b_int32.npy')).astype(np.int64)
    sw = np.asarray(L['weight_scale'], dtype=np.float64)
    mc = np.round(L['act_in_scale'] * sw / L['act_out_scale'] * (2.0 ** F_MC)).astype(np.int64)
    xf = np.load(os.path.join(SMP, name + '_in_int8.npy'))[0].astype(np.int64)
    x = xf[:, r0:r0 + ht, c0:c0 + wd]
    acc = conv_gold(x, w, b)
    q = (acc * mc[:, None, None] + (1 << (F_MC - 1))) >> F_MC
    q = np.clip(q, -128, 127)
    q = np.maximum(q, 0)                       # 10 层 relu_after 全 1
    emit_in(os.path.join(VEC, tag + '_in.hex'), x)
    emit_exp(os.path.join(VEC, tag + '_exp.hex'), q.astype(np.int64))
    print('%-7s joint patch rows %d..%d cols %d..%d  acc[%d..%d] q[%d..%d] bank=%d'
          % (tag, r0, r0 + ht - 1, c0, c0 + wd - 1, acc.min(), acc.max(),
             q.min(), q.max(), li))
    return {'tag': tag, 'layer': name, 'bank': li, 'rows': [r0, ht], 'cols': [c0, wd],
            'in_hex': tag + '_in.hex', 'exp_hex': tag + '_exp.hex'}


joint = [
    make_joint('joint0', 0, 200, 400),
    make_joint('joint1', 1, 100, 200),
    # W=1024 全宽条带: 覆盖 cfg_w/rd_req_len=1024、hp_l、行缓冲满深度
    make_joint('joint2', 0, 200, 0, wd=1024, ht=2),
]
open(os.path.join(VEC, 'joint_meta.json'), 'w', encoding='utf-8', newline='\n').write(
    json.dumps({'patches': joint, 'note': 'M6 pe_layer + M7 wram_bank end-to-end'}, indent=2) + '\n')

print('\n[ok] mem -> %s' % MEM)
print('[ok] vec -> %s' % VEC)
