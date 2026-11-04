#!/usr/bin/env python3
"""gen_fpga_mem.py —— 由 quant_params.json 生成 MFL 卷积核的 BRAM 初始化与层配置 (IP 侧 $readmemh)

用法: python gen_fpga_mem.py <quant_params.json> <输出目录>
约定(Kosmo2_IP docs/03 §4 + 移交清单 v1.2 §5a):
  F=24 全网统一; conv requant: y = (acc32 × Mc[c] + 2^(F-1)) >>> F (round), clamp(-128,127) → ReLU;
  Mc[c] = round(act_in_i × s_w[c] / act_out_i × 2^F) —— 输入域 = act_in_i(边界 requant 后的本层输入域,
  与 fpga_sim.py/ORT 一致; ORT 的中间 relu-Q 不存在于硬件链); 校验 |Mc| < 2^31。
  边界 requant: Mc_b = round(act_out_i / act_in_{i+1} × 2^F) —— relu(+/池化) 后、下层 conv 前。
  v3.1 地址定案(三方复查 2026-10-10): L0 in=0x302000(避开 0x301000 邮箱页);
  final OUT=0x470000(避 IN slot0 数据区 [0x302000,0x462000)); scratch 固定双区
  A=0x500000(容 L0 7.5MiB)/B=0xD00000; IN slot1=0x1500000(三方会签, gen 不产出)。
产出: weights.mem / bias.mem / mc.mem / boundary.mem / layer_config.mem / fpga_mem_README.md
"""
import json, sys
import numpy as np
from pathlib import Path

F = 24
MAILBOX_BASE   = 0x00301000   # 6 寄存器邮箱页(64B), 数据区避开
IN0_DATA       = 0x00302000   # IN slot0 数据起点(v3.1: 避邮箱页)
OUT_FINAL      = 0x00470000   # 实模式 final OUT(v3.1: 避 IN slot0 数据区)
IN_BUF, OUT_BUF = 0x00300000, OUT_FINAL   # 兼容旧变量名: IN_BUF 仅作窗基址语义
A_BASE, B_BASE = 0x00500000, 0x00D00000   # 固定乒乓双区(A 容 7.5MiB; 旧 SCR1@0x900000 与 A 交叠, 弃用)
WRITE_BACK = [(480, 1024), (240, 512), (240, 512), (120, 256), (120, 256),
              (60, 128), (60, 128), (30, 64), (30, 64), (15, 32)]  # 各层写回尺寸(block 末层含池化)

def main():
    qp = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
    wdir = Path(sys.argv[1]).parent / "weights_int8"
    layers = qp["conv_layers"]
    entries, w_off, b_off, m_off = [], 0, 0, 0
    w_lines, b_lines, m_lines, r_lines = [], [], [], []

    for i, L in enumerate(layers):
        oc = int(L["w_shape"][0]); ic = int(L["w_shape"][1])
        # Design A: 本层输入域 = act_in_i(边界 requant 已由上一层输出级完成, 与 fpga_sim/ORT 一致)
        s_in = float(np.ravel(L["act_in_scale"])[0])
        s_out = float(np.ravel(L["act_out_scale"])[0])
        ws = np.ravel(L["weight_scale"]).astype(np.float64)
        assert ws.size == oc, f"layer{i} w_scale 数量不符"
        mc = np.round(s_in * ws / s_out * (1 << F)).astype(np.int64)
        assert (np.abs(mc) < (1 << 31)).all(), f"layer{i} Mc 溢出 int31, 需加大 F 或调 scale"
        bias = L.get("bias_int32")
        bq = np.ravel(np.array(bias, dtype=np.int64)) if bias is not None else np.zeros(oc, np.int64)
        w = np.load(wdir / f"conv{i:02d}_w_int8.npy")          # int8 (oc, ic, 3, 3)
        assert w.shape == (oc, ic, 3, 3)
        w_flat = w.transpose(2, 3, 1, 0).reshape(-1)            # [k][ic][c], c 最快
        # v3.1 量产显式基址表(替代奇偶推导——L0 7.5MiB 与 SCR1@0x900000 碰撞, 实测复现):
        # 固定双区 A=0x500000(容 L0 7.5MiB) / B=0xD00000(容最大奇层 1.875MiB), 逐层无交叠
        in_addr = IN0_DATA if i == 0 else (A_BASE if i % 2 == 1 else B_BASE)  # = L(i-1) 的写区(A/B 交替)
        out_addr = OUT_FINAL if i == len(layers) - 1 else (A_BASE if i % 2 == 0 else B_BASE)
        entries.append({
            "layer": i, "oc": oc, "ic": ic,
            "oh": WRITE_BACK[i][0], "ow": WRITE_BACK[i][1],
            "pool": 1 if i % 2 == 1 else 0,
            "in_addr": in_addr, "out_addr": out_addr,
            "w_off": w_off, "w_bytes": int(w_flat.size),
            "b_off": b_off, "m_off": m_off, "s_in": s_in, "s_out": s_out,
        })
        w_lines += [f"{int(v) & 0xFF:02X}" for v in w_flat]
        b_lines += [f"{int(v) & 0xFFFFFFFF:08X}" for v in bq]
        m_lines += [f"{int(v) & 0xFFFFFFFF:08X}" for v in mc]
        w_off += int(w_flat.size); b_off += oc * 4; m_off += oc * 4

    # 边界 requant 标量: act_out_i -> act_in_{i+1} (L9 -> head 由 GAP_K 承担, 不在此列)
    for i in range(len(layers) - 1):
        so = float(np.ravel(layers[i]["act_out_scale"])[0])
        si = float(np.ravel(layers[i + 1]["act_in_scale"])[0])
        mb = np.round(so / si * (1 << F)).astype(np.int64)
        assert abs(mb) < (1 << 31), f"boundary{i} 溢出"
        r_lines.append(f"{int(mb) & 0xFFFFFFFF:08X}")

    nl = chr(10)
    (out / "weights.mem").write_text(nl.join(w_lines) + nl, encoding="ascii", newline=chr(10))
    (out / "bias.mem").write_text(nl.join(b_lines) + nl, encoding="ascii", newline=chr(10))
    (out / "mc.mem").write_text(nl.join(m_lines) + nl, encoding="ascii", newline=chr(10))
    (out / "boundary.mem").write_text(nl.join(r_lines) + nl, encoding="ascii", newline=chr(10))
    lc = ["// in_addr out_addr ic oc oh ow pool w_off(B) b_off(B) mc_off(B)  [v3.1 fixed 2-region: even=A@0x500000, odd=B@0xD00000]",
          f"// F={F} conv requant: y=(acc*Mc+2^(F-1))>>>F, round; boundary requant: see boundary.mem; L0 in=0x302000, L9 out=0x470000 (v3.1)"]
    for e in entries:
        lc.append(f"{e['in_addr']:08X} {e['out_addr']:08X} {e['ic']:02X} {e['oc']:02X} "
                  f"{e['oh']:03X} {e['ow']:03X} {e['pool']:X} {e['w_off']:08X} {e['b_off']:08X} {e['m_off']:08X}")
    (out / "layer_config.mem").write_text(nl.join(lc) + nl, encoding="ascii", newline=chr(10))

    doc = ["# fpga_mem 包 (gen_fpga_mem.py 自动生成, D 链 Entropy+2048)",
           f"- F = {F} (全网统一); conv requant: y = (acc32 × Mc[c] + 2^(F-1)) >>> F, round, clamp(-128,127)",
           "- boundary.mem: 边界 requant 标量 Mc_b = round(act_out_i / act_in_(i+1) × 2^F), int32 ×9;",
           "  硬件在 relu(+/池化) 后、下层 conv 前施乘移位 (相等边界恒等, 统一实施)",
           "- weights.mem: 布局 [layer][k][ic][c] c 最快; 层内基址见 layer_config.mem 的 w_off",
           "- bias.mem: int32 累加器域偏置; mc.mem: int32 每输出通道",
           "- layer_config.mem: 每层一行(in/out 为物理地址; scratch 固定双区 A=0x500000/B=0xD00000; L0 in=0x302000 避邮箱页; L9 out=0x470000)",
           "", "| layer | in→out ch | 写回 H×W | pool | w_off(B) | in_addr | out_addr |",
           "|---|---|---|---|---|---|---|"]
    for e in entries:
        doc.append(f"| L{e['layer']} | {e['ic']}→{e['oc']} | {e['oh']}×{e['ow']} | {e['pool']} "
                   f"| {e['w_off']:#x} | {e['in_addr']:#x} | {e['out_addr']:#x} |")
    (out / "fpga_mem_README.md").write_text(nl.join(doc) + nl, encoding="utf-8")
    print(f"[fpga_mem] weights={w_off}B bias={b_off}B mc={m_off}B boundary={len(r_lines)} -> {out}")
    for e in entries:
        print(f"  L{e['layer']}: {e['ic']:2d}->{e['oc']:2d} pool={e['pool']} "
              f"w@{e['w_off']:#08x} in={e['in_addr']:#x} out={e['out_addr']:#x}")

if __name__ == "__main__":
    main()
