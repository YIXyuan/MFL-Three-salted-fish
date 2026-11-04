#!/usr/bin/env python3
"""fpga_sim.py —— MFL 卷积核 F=24 定点全链仿真器 (V4 门禁 L1 锚点 + L2/L3 校准器)

数值语义严格对齐 Kosmo2_IP docs/03 §4 硬件数据流:
  acc32 = bias_i32 + Σ(x_i8 · w_i8)                       # INT32 累加(含偏置, 累加器域)
  y     = (acc32 × Mc[c]) >>> 24                          # 算术右移 = floor(无 round-half)
  q     = clamp(y, -128, 127) → ReLU(q<0→0)               # 逐元素
  pool  = 2×2 s2 max(int8), 仅 block 末层写回时(conv01/03/05/07/09)
层间 scratch 乒乓与地址只影响数据搬运不影响数值, 仿真不模拟。

用法:
  python fpga_sim.py --params <quant_params.json> --input <P0001_001.input_int8.bin|jpg>
                      [--weights-dir <weights_int8 目录>] [--outdir <报告目录>]
输出:
  - 逐层 pre-ReLU pre-pool int8 张量 (对应板上 LAYER=0x300|N 导出口径, G2.5 对拍用)
  - 最终 feat (96,15,32) post-relu+pool + head 复刻 probs (L3 对拍)
  - 与 ORT round 链参考(*_out_int8.npy, 若提供 --ref-dir)的逐层偏差分布 (τ₂ 证据)
"""
import argparse
import json
from pathlib import Path

import numpy as np

F = 24
POOL_LAYERS = {1, 3, 5, 7, 9}
ROUNDING = "round"   # "round"(契约 v1.2, 与 ORT 对齐) | "floor"(docs/03 §4 原始口径; L1 若硬件按 floor 实现)


def load_input(path):
    p = Path(path)
    if p.suffix == ".bin":                                    # 裸 int8 (3,480,1024) CHW
        x = np.fromfile(p, dtype=np.int8)
        assert x.size == 3 * 480 * 1024, f"输入尺寸不符: {x.size}"
        return x.reshape(3, 480, 1024)
    from PIL import Image
    im = Image.open(p).convert("RGB")
    assert im.size == (1024, 480), f"尺寸不符: {im.size}"
    a = np.asarray(im, dtype=np.uint8)
    return (a >> 1).astype(np.int8).transpose(2, 0, 1)        # /255→×127 等价 >>1


def conv_layer(x, w, bq, mc, pool, ratio_next=1.0, rounding=ROUNDING):
    """x: (ic,H,W) int8; w: (oc,ic,3,3) int8; bq/mc: (oc,) int64/int. 返回 int8 (oc,oh,ow)."""
    ic, H, W = x.shape
    oc = w.shape[0]
    xp = np.zeros((ic, H + 2, W + 2), dtype=np.int8)          # padding=0 (Conv pads=1)
    xp[:, 1:-1, 1:-1] = x
    acc = np.zeros((oc, H, W), dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            win = xp[:, kh:kh + H, kw:kw + W].astype(np.int64)      # (ic,H,W)
            wk = w[:, :, kh, kw].astype(np.int64)                    # (oc,ic)
            acc += np.tensordot(wk, win, axes=([1], [0]))            # 精确整数, 界内=int32 硬件
    acc += bq[:, None, None]
    bias_shift = (1 << (F - 1)) if rounding == "round" else 0  # round: 加 2^(F-1) 偏置; floor: 直接右移
    y = (acc * mc[:, None, None] + bias_shift) >> F           # 算术右移
    q = np.clip(y, -128, 127)
    pre = q.astype(np.int8)                                   # [修正 2026-10-15] pre-ReLU pre-pool
    # (0x300|N 导出口径) —— 原实现在 pool 之后赋值, 奇数层 dump 实为 post-pool(云端审计发现),
    # 曾导致 golden_dualplane 奇数层错标; pool/ReLU 只影响链上 q, 不影响本捕获
    if pool:
        q = q.reshape(oc, H // 2, 2, W // 2, 2).max(axis=(2, 4))
    q = np.maximum(q, 0)                                      # ReLU (floor 后 g 负值归零)
    # v3 边界 requant: act_out_i 域 -> act_in_{i+1} 域 (ORT QDQ 双 Q 语义; 恒等时 ratio=1)
    q = np.clip(np.rint(q.astype(np.float32) * np.float32(ratio_next)), -128, 127)
    return q.astype(np.int8), pre


def head_forward(feat_i8, hp, blob):
    """ARM 定点头复刻(与 T2 kit head.c 同序): GAP→q1→fc1→双级requant→fc2."""
    f32 = np.float32
    s1i, s1o = f32(hp["s_fc1_in"]), f32(hp["s_fc1_out"])
    s2i, s2o = f32(hp["s_fc2_in"]), f32(hp["s_fc2_out"])
    gap_k = f32(hp["gap_k"])
    rr = f32(s1o / s2i)
    fc1_w = np.frombuffer(blob[:256 * 96], dtype=np.int8).reshape(256, 96)
    fc1_bq = np.frombuffer(blob[24576:24576 + 1024], dtype=np.int32)
    fc2_w = np.frombuffer(blob[25600:25600 + 768], dtype=np.int8).reshape(3, 256)
    fc2_bq = np.frombuffer(blob[26368:26368 + 12], dtype=np.int32)
    w1s = np.array(hp["fc1_w_scale"], dtype=np.float32)
    w2s = np.array(hp["fc2_w_scale"], dtype=np.float32)
    s = feat_i8.reshape(96, -1).astype(np.int32).sum(axis=1)
    q1 = np.clip(np.rint(s.astype(np.float32) * gap_k), -128, 127).astype(np.int32)
    acc = q1 @ fc1_w.T.astype(np.int32) + fc1_bq
    y = acc.astype(np.float32) * (s1i * w1s)
    q2 = np.clip(np.rint(y / s1o), -128, 127)
    q2 = np.clip(np.rint(np.maximum(q2, 0).astype(np.float32) * rr), -128, 127).astype(np.int32)
    acc2 = q2 @ fc2_w.T.astype(np.int32) + fc2_bq
    y2 = acc2.astype(np.float32) * (s2i * w2s)
    ql = np.clip(np.rint(y2 / s2o), -128, 127).astype(np.int32)
    logits = ql.astype(np.float32) * s2o
    e = np.exp(logits - logits.max())
    return logits, e / e.sum(), int(np.argmax(logits))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default="quant_params.json")
    ap.add_argument("--weights-dir", default=None, help="weights_int8 目录(默认 params 同级)")
    ap.add_argument("--input", required=True, help="input_int8.bin 或 1024x480 jpg")
    ap.add_argument("--head-bin", default=None, help="mfl_head.bin(L3 probs 输出用)")
    ap.add_argument("--ref-dir", default=None, help="含 convNN_out_int8.npy 的参考目录(τ₂ 证据)")
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--dump-layers", action="store_true",
                    help="逐层导出 pre-ReLU pre-pool int8 npy (golden 包, 供 TB/逐层对拍)")
    ap.add_argument("--requant-rounding", default="round", choices=["round", "floor"],
                    help="L1 位级对拍时须与硬件实现一致(docs/03 原 floor / 契约 v1.2 round)")
    args = ap.parse_args()

    qp = json.loads(Path(args.params).read_text(encoding="utf-8"))
    wdir = Path(args.weights_dir or (Path(args.params).parent / "weights_int8"))
    x = load_input(args.input)
    out = Path(args.outdir); out.mkdir(exist_ok=True)

    layer_tensors, dev_rows, ratios = [], [], []
    for i, L in enumerate(qp["conv_layers"]):
        oc, ic = int(L["w_shape"][0]), int(L["w_shape"][1])
        s_in = float(np.ravel(L["act_in_scale"])[0])   # = 边界 requant 后的本层输入域(Design A)
        s_out = float(np.ravel(L["act_out_scale"])[0])
        ws = np.ravel(L["weight_scale"]).astype(np.float64)
        mc = np.round(s_in * ws / s_out * (1 << F)).astype(np.int64)   # requant -> act_out 域
        ratio_next = (s_out / float(np.ravel(qp["conv_layers"][i + 1]["act_in_scale"])[0])
                      if i + 1 < len(qp["conv_layers"]) else 1.0)  # 边界 requant(L9 由 head GAP_K 承担)
        ratios.append(ratio_next)
        assert (np.abs(mc) < (1 << 31)).all(), f"L{i} Mc 溢出"
        bq = (np.ravel(np.array(L["bias_int32"], dtype=np.int64))
              if L.get("bias_int32") else np.zeros(oc, np.int64))
        w = np.load(wdir / f"conv{i:02d}_w_int8.npy")
        q, pre = conv_layer(x, w, bq, mc, pool=(i in POOL_LAYERS), ratio_next=ratio_next,
                              rounding=args.requant_rounding)
        if args.dump_layers:
            np.save(out / f"layer{i:02d}_pre_relu_int8.npy", pre)
        pre = q.copy()                                        # post-relu(+pool) —— 存档口径
        layer_tensors.append(q)
        if args.ref_dir:
            ref_p = Path(args.ref_dir) / f"conv{i:02d}_out_int8.npy"
            if ref_p.exists():
                ref = np.load(ref_p)
                # [修正 2026-10-15] ref 语义 = pre-ReLU pre-pool ORT 张量(fcf1d64e / 新向量集同口径),
                # 对拍对象是 pre(原实现比的是链上 post-relu/pool 的 q, 且 reshape 会崩/错位)
                if ref.size != pre.size:
                    raise SystemExit(f"L{i}: ref {ref.shape} 与 sim pre {pre.shape} 元素数不符——"
                                     "ref 口径不是 pre-ReLU pre-pool?")
                ref = ref.reshape(pre.shape)
                d = np.abs(ref.astype(np.int32) - pre.astype(np.int32))
                dev_rows.append({"layer": i, "n": int(d.size),
                                 "equal": int((d == 0).sum()),
                                 "d1": int((d == 1).sum()), "d2": int((d >= 2).sum()),
                                 "max": int(d.max())})
        x = q                                                 # 下一层输入
        del layer_tensors[:-6]                                # 保内存: 只留最近若干层

    feat = layer_tensors[-1]
    np.save(out / "sim_feat_int8.npy", feat)
    report = {"input": args.input, "F": F,
              "boundary_ratios": [round(float(r), 9) for r in ratios],
              "feat_shape": list(feat.shape), "feat_min": int(feat.min()), "feat_max": int(feat.max()),
              "sat_ratio": float((np.abs(feat.astype(np.int32)) >= 127).mean()),
              "zero_channel": int((feat.reshape(96, -1).max(axis=1) == 0).sum())}
    if args.ref_dir:
        report["ref_deviation"] = dev_rows
    if args.head_bin:
        hp_json = Path(args.params).parent / "c_params" / "head_params.json"
        blob = Path(args.head_bin).read_bytes()
        s_feat = float(np.ravel(qp["conv_layers"][9]["act_out_scale"])[0])
        s_fc1_in = float(np.ravel(qp["head_layers"][0]["act_in_scale"])[0])
        hp = {"s_fc1_in": qp["head_layers"][0]["act_in_scale"],
              "s_fc1_out": qp["head_layers"][0]["act_out_scale"],
              "s_fc2_in": qp["head_layers"][1]["act_in_scale"],
              "s_fc2_out": qp["head_layers"][1]["act_out_scale"],
              "fc1_w_scale": qp["head_layers"][0]["weight_scale"],
              "fc2_w_scale": qp["head_layers"][1]["weight_scale"],
              "gap_k": s_feat / (480 * s_fc1_in)}
        logits, probs, am = head_forward(feat, hp, blob)
        report["head"] = {"logits": [round(float(v), 6) for v in logits],
                          "probs": [round(float(v), 6) for v in probs], "pred": am}
    (out / "fpga_sim_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1),
                                              encoding="utf-8")
    print(f"[sim] feat {feat.shape} range[{feat.min()},{feat.max()}] "
          f"饱和占比 {report['sat_ratio']:.4%} 全零通道 {report['zero_channel']}")
    for r in dev_rows:
        print(f"  L{r['layer']}: vs round-ref 相等 {r['equal']}/{r['n']} |Δ|1={r['d1']} "
              f"|Δ|≥2={r['d2']} max={r['max']}")
    if "head" in report:
        print(f"  head probs = {report['head']['probs']} pred={report['head']['pred']}")
    print(f"[sim] 报告: {out / 'fpga_sim_report.json'}")


if __name__ == "__main__":
    main()
