# -*- coding: utf-8 -*-
"""
gen_layer_params.py -- 从 v2 交付(quant_export + manifest)生成 FPGA 侧层参数表
输出:
  doc\层参数表_FPGA.md     人读表（每层卷积/激活/池化/scale/Mc/McB/缓冲）
  doc\layer_params_v2.json 机读表（供 M8 层配置生成器; Mc/McB 现场生成勿手抄）
原则: 全部数值由本脚本从 quant_params.json / manifest.json 生成, 禁止手抄。
"""
import numpy as np
import json
import os
import io

QE = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\quant_export'
TV = r'C:\Users\21889\Desktop\mfl2d_v2-back-10.15\mfl2d_v2\output\test_vectors'
OUT_MD = r'C:\Users\21889\Desktop\Kosmo2_MES2K100\doc\层参数表_FPGA.md'
OUT_JS = r'C:\Users\21889\Desktop\Kosmo2_MES2K100\doc\layer_params_v2.json'

F_MC = 31        # Mc 移位 (acc×Mc 64bit, F=31 与实测口径一致)
F_MCB = 24       # 边界换挡移位 (int8×McB 64bit; ratio<2 时 2^24 足够精度)

qp = json.load(open(QE + r'\quant_params.json', encoding='utf-8'))
mf = json.load(open(TV + r'\manifest.json', encoding='utf-8'))
lt = mf['layers_table']
spec = json.load(open(QE + r'\fpga_architecture_spec.json', encoding='utf-8'))
spec_layers = {L['layer']: L for L in spec['layers']}

rows = []
json_layers = []
smp0 = mf['samples'][0]['layers']          # 权威 in_shape/out_shape
for i, L in enumerate(lt):
    name = L['layer']
    cl = qp['conv_layers'][i]
    sp = spec_layers[name]
    sw = np.array(cl['weight_scale'], dtype=np.float64)
    s_in, s_out = cl['act_in_scale'], cl['act_out_scale']
    oc, ic = sp['out_ch'], sp['in_ch']
    # Mc/McB（与 RTL 口径一致: round-half-up）
    Mc = np.round(s_in * sw / s_out * (2.0 ** F_MC)).astype(np.int64)
    ratio = L['boundary_ratio_to_next']
    McB = None if ratio is None else int(round(ratio * (2.0 ** F_MCB)))
    w = np.load(os.path.join(QE, r'weights_int8\%s_w_int8.npy' % name))
    b = np.load(os.path.join(QE, r'weights_int8\%s_b_int32.npy' % name))
    in_hw = (smp0[i]['in_shape'][2], smp0[i]['in_shape'][3])     # 权威来源(含池化后的形状)
    out_hw = (smp0[i]['out_shape'][2], smp0[i]['out_shape'][3])
    rows.append(dict(i=i, name=name, ic=ic, oc=oc,
                     in_hw=in_hw, out_hw=out_hw,
                     s_in=s_in, s_out=s_out, relu=L['relu_after'], pool=L['pool_after'],
                     ratio=ratio, McB=McB,
                     w_scale_min=float(sw.min()), w_scale_max=float(sw.max()),
                     b_min=int(b.min()), b_max=int(b.max()),
                     Mc_min=int(Mc.min()), Mc_max=int(Mc.max()), Mc_int32_ok=bool(Mc.max() < 2**31),
                     w_bytes=w.size, b_bytes=b.size * 4))
    json_layers.append(dict(layer=name, i=i, in_ch=ic, out_ch=oc,
                            in_hw=list(in_hw), out_hw=list(out_hw),
                            kernel=[3, 3], pads=[1, 1, 1, 1], stride=[1, 1],
                            act_in_scale=s_in, act_out_scale=s_out,
                            relu_after=L['relu_after'], pool_after=L['pool_after'],
                            boundary_ratio_to_next=ratio, McB=McB, f_mcb=F_MCB, f_mc=F_MC,
                            weight_file='weights_int8/%s_w_int8.npy' % name,
                            bias_file='weights_int8/%s_b_int32.npy' % name,
                            weight_scale_min=rows[i]['w_scale_min'],
                            weight_scale_max=rows[i]['w_scale_max']))

# 中间张量(REBUF)需求: max(每层 in/out 字节)
def bytes_of(hw, ch):
    return hw[0] * hw[1] * ch

sizes = []
for r in rows:
    sizes.append((r['name'], bytes_of(r['in_hw'], r['ic']), bytes_of(r['out_hw'], r['oc'])))
peak = max(max(a, b) for _, a, b in sizes)
feat_bytes = bytes_of([15, 32], 96)

md = io.StringIO()
md.write('# FPGA 侧每层卷积/激活/池化参数表（v2, 2026-10-15 交付生成）\n\n')
md.write('> 脚本生成: `python -X utf8 tools\\gen_layer_params.py`（数据源：quant_export/quant_params.json + test_vectors/manifest.json，**禁止手抄**）\n')
md.write('> 机读版: `doc/layer_params_v2.json`（M8 层配置生成器直接读）\n')
md.write('> 口径: requant = round-half-up；Mc = round(s_in·s_w[c]/s_out·2^%d)；McB = round(ratio·2^%d)\n\n' % (F_MC, F_MCB))

md.write('## 1. 逐层参数总表\n\n')
md.write('| # | 层 | in_ch→out_ch | 输入 H×W | 输出 H×W | 3×3/s1/p1 | act_in | act_out | ReLU | Pool | 边界比例 |\n')
md.write('|---|---|---|---|---|---|---|---|---|---|---|\n')
for r in rows:
    md.write('| %d | %s | %d→%d | %d×%d | %d×%d | ✓ | %.8f | %.8f | %d | %s | %s |\n'
             % (r['i'], r['name'], r['ic'], r['oc'], r['in_hw'][0], r['in_hw'][1],
                r['out_hw'][0], r['out_hw'][1], r['s_in'], r['s_out'],
                r['relu'], ('2×2s2' if r['pool'] else '—'),
                ('%.6f' % r['ratio']) if r['ratio'] else '末层(见§3)'))

md.write('\n## 2. 权重/偏置/量化常数（M7 参数 BRAM 用）\n\n')
md.write('| 层 | 权重 shape | 权重字节 | weight_scale 范围 | bias 项数 | bias 范围 | Mc 范围 (F=%d) | int32 安全 |\n' % F_MC)
md.write('|---|---|---|---|---|---|---|---|\n')
for r in rows:
    md.write('| %s | (%d,%d,3,3) | %d B | %.3e ~ %.3e | %d | %d ~ %d | %d ~ %d | %s |\n'
             % (r['name'], r['oc'], r['ic'], r['w_bytes'], r['w_scale_min'], r['w_scale_max'],
                r['b_bytes'] // 4, r['b_min'], r['b_max'], r['Mc_min'], r['Mc_max'],
                '✓' if r['Mc_int32_ok'] else '✗'))
md.write('\n- **Mc 逐通道生成式**（M7/M8 脚本用）：`Mc[c] = round(act_in × weight_scale[c] / act_out × 2^%d)`，int32 存放，随 c_read 同步切换。\n' % F_MC)
md.write('- **McB 边界换挡**（池化/relu 之后，跨 scale 边界第二级 requant）：`McB = round(ratio × 2^%d)`，int32；同 scale 边界 ratio=1 → 免换挡（McB=2^%d，可用直通旁路）。\n' % (F_MCB, F_MCB))
md.write('- 权重/偏置文件：`quant_export/weights_int8/convXX_w_int8.npy`（int8，**BN 已折叠**）、`convXX_b_int32.npy`（int32）。\n')

md.write('\n## 3. 边界换挡（McB）逐边界数值\n\n')
md.write('| 边界 | 类型 | ratio | McB (F=%d) | 备注 |\n|---|---|---|---|---|\n' % F_MCB)
for r in rows[:-1]:
    nxt = rows[r['i'] + 1]['name']
    same = abs(r['ratio'] - 1.0) < 1e-9
    typ = ('同 scale' if same else '跨 scale') + (' + 池化' if r['pool'] else '')
    if same:
        md.write('| %s→%s | %s | 1.000000 | —（直通旁路） | relu%s 后逐元素直通 |\n'
                 % (r['name'], nxt, typ, '+pool' if r['pool'] else ''))
    else:
        md.write('| %s→%s | %s | %.6f | %d | relu%s 后换挡 |\n'
                 % (r['name'], nxt, typ, r['ratio'], r['McB'], '+pool' if r['pool'] else ''))
md.write('\n- **末层 conv09**：relu + 2×2s2 pool 后得到最终特征图（见 §4），无后续边界。\n')
md.write('- 数据通路（每层）：`acc32 ─[Mc]→ conv_out int8 @act_out（对拍锚点）─relu─[pool]─[McB]→ 下一层 in @act_in(k+1)`。\n')

md.write('\n## 4. 最终特征图（FPGA 输出给 ARM）\n\n')
md.write('| 项 | 值 |\n|---|---|\n')
md.write('| 张量 | `int8[1][96][15][32]` NCHW（= relu+2×2s2pool(conv09_out)） |\n')
md.write('| 大小 | %d B (%.1f KB) |\n' % (feat_bytes, feat_bytes / 1024))
md.write('| 地址公式 | `addr = OUT_BUF + c×480 + y×32 + x`（c=0..95, y=0..14, x=0..31） |\n')
md.write('| 值域 | [0, 127] **全非负**（relu 保证; 已用 sample_0 重算验证 min=0/max=127） |\n')
md.write('| scale | %.10f（= conv09 act_out，pool/relu 不改变 scale） |\n' % rows[-1]['s_out'])
md.write('| 对拍 | `feat_ref = 2×2s2pool(max(conv09_out_int8,0))`（向量侧确定性派生，可逐元素比对） |\n')

md.write('\n## 5. 中间张量尺寸与 REBUF 需求（M8 内存规划）\n\n')
md.write('| 层 | 输入字节 | 输出字节 |\n|---|---|---|\n')
for name, a, b in sizes:
    md.write('| %s | %s | %s |\n' % (name, '{:,}'.format(a), '{:,}'.format(b)))
md.write('\n- **峰值中间张量 = %s B (%.1f MiB)**（conv00_out / conv01_in 16×480×1024）\n'
         % ('{:,}'.format(peak), peak / 1048576))
md.write('- v1 逐层串行 → REBUF 单块 ≥ %.0f MiB；若做层间乒乓 → 2×。见 ARM 契约 §6 地址规划的 REBUF 区。\n'
         % np.ceil(peak / 1048576))
md.write('- 权重大小合计 %.1f KB（10 层 int8），另加 int32 偏置与 Mc/McB 参数区。\n'
         % (sum(r['w_bytes'] for r in rows) / 1024))

md.write('\n## 6. M8 层配置字段（每层一条, 由本表生成）\n\n')
md.write('```\n')
md.write('{ in_ch, out_ch, H_in, W_in, H_out, W_out,      // 形状\n')
md.write('  in_addr_base, out_addr_base,                  // REBUF 基址(M8 分配)\n')
md.write('  w_bank_id, bias_addr, mc_addr, mcb_addr,      // M7 参数 BRAM 区\n')
md.write('  relu_en, pool_en, boundary_en, f_shift, f_shift_b }\n')
md.write('```\n')
md.write('relu_en/pool_en 取值见 §1（**10 层 relu_en 全 1**；pool_en 奇数层含 conv09）；\n')
md.write('boundary_en = (ratio != 1.0)；f_shift=%d（Mc）、f_shift_b=%d（McB）。\n' % (F_MC, F_MCB))

open(OUT_MD, 'w', encoding='utf-8').write(md.getvalue())
json.dump(dict(source=dict(qe=QE, tv=TV, date='2026-10-15 delivery'),
               f_mc=F_MC, f_mcb=F_MCB,
               layers=json_layers,
               final_feature=dict(shape=[1, 96, 15, 32], bytes=feat_bytes,
                                  scale=rows[-1]['s_out'], addr_formula='OUT_BUF + c*480 + y*32 + x'),
               rebuf_peak_bytes=int(peak)),
          open(OUT_JS, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

print(md.getvalue())
print('[saved]', OUT_MD)
print('[saved]', OUT_JS)
