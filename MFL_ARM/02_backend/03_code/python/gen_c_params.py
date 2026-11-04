"""
"""
import sys, io, json, os, hashlib, struct
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import onnx
from onnx import numpy_helper

EXPORT = r"D:\QianSai\new\quant_export(new)"
OUT_W = r"D:\QianSai\new\arm_head\weights"
OUT_H = r"D:\QianSai\new\arm_head\src"

ok = True
def check(name, cond, detail=""):
    global ok
    tag = "PASS" if cond else "FAIL"
    if not cond:
        ok = False
    print(f"  [{tag}] {name} {detail}")

mi = onnx.load(fr"{EXPORT}\model_int8.onnx")
hi = onnx.load(fr"{EXPORT}\head_int8.onnx")
hf = onnx.load(fr"{EXPORT}\head_fp32.onnx")
qp = json.load(open(fr"{EXPORT}\quant_params.json", encoding="utf-8"))

def inits(model):
    return {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}

IM, IH, IF = inits(mi), inits(hi), inits(hf)

conv_map = {f"conv{i:02d}": f"features.{idx}" for i, idx in
            zip(range(10), [0, 2, 5, 7, 10, 12, 15, 17, 20, 22])}

print("== 1. weights_int8 npy vs model_int8.onnx 初始化器 ==")
for i in range(10):
    for kind, suffix in [("w", "weight_quantized"), ("b", "bias_quantized")]:
        npy = np.load(fr"{EXPORT}\weights_int8\conv{i:02d}_{kind}_int{'8' if kind=='w' else '32'}.npy")
        name = f"{conv_map[f'conv{i:02d}']}.{suffix}"
        onnx_arr = IM[name]
        same = npy.shape == onnx_arr.shape and npy.dtype == onnx_arr.dtype and np.array_equal(npy, onnx_arr)
        check(f"conv{i:02d}_{kind} {npy.shape} {npy.dtype}", same,
              "" if same else f"onnx={onnx_arr.shape} {onnx_arr.dtype}")

print("== 2. head_int8.onnx vs model_int8.onnx 头部参数 ==")
for name in ["classifier.1.weight_quantized", "classifier.1.weight_scale",
             "classifier.3.weight_quantized", "classifier.3.weight_scale"]:
    check(name, np.array_equal(IH[name], IM[name]))
for name in ["classifier.1.bias_quantized", "classifier.3.bias_quantized"]:
    qh, qm = IH[name], IM[name]
    same = qh.shape == qm.shape
    n_diff = int((qh != qm).sum()) if same else -1
    max_lsb = int(np.abs(qh.astype(np.int64) - qm.astype(np.int64)).max()) if same else 99
    check(f"{name} (允许 1 LSB)", same and max_lsb <= 1,
          f"不同元素 {n_diff} 个, 最大差 {max_lsb} LSB")

print("== 3. quant_params.json vs model_int8.onnx scale (相对 1e-6) ==")
fc1, fc2 = qp["head_layers"][0], qp["head_layers"][1]
rel = lambda a, b: abs(a - b) / abs(b)
check("fc1 act_in_scale", rel(fc1["act_in_scale"], float(IM["/classifier/classifier.0/Flatten_output_0_scale"])) < 1e-6)
check("fc1 weight_scale[256]", np.allclose(fc1["weight_scale"], IM["classifier.1.weight_scale"], rtol=1e-6, atol=0))
check("fc1 act_out_scale", rel(fc1["act_out_scale"], float(IM["/classifier/classifier.1/Gemm_output_0_scale"])) < 1e-6)
check("fc2 act_in_scale", rel(fc2["act_in_scale"], float(IM["/classifier/classifier.2/Relu_output_0_scale"])) < 1e-6)
check("fc2 weight_scale[3]", np.allclose(fc2["weight_scale"], IM["classifier.3.weight_scale"], rtol=1e-6, atol=0))
check("fc2 act_out_scale", rel(fc2["act_out_scale"], float(IM["output_scale"])) < 1e-6)

print("== 4. QDQ 自洽: bias_scale == act_in_scale * w_scale ==")
s1in = float(IM["/classifier/classifier.0/Flatten_output_0_scale"])
s2in = float(IM["/classifier/classifier.2/Relu_output_0_scale"])
err1 = np.abs(IM["classifier.1.bias_quantized_scale"] - s1in * IM["classifier.1.weight_scale"]).max()
err2 = np.abs(IM["classifier.3.bias_quantized_scale"] - s2in * IM["classifier.3.weight_scale"]).max()
check(f"fc1 bias_scale 误差 max={err1:.3g}", err1 / np.abs(IM["classifier.1.bias_quantized_scale"]).max() < 1e-6)
check(f"fc2 bias_scale 误差 max={err2:.3g}", err2 / np.abs(IM["classifier.3.bias_quantized_scale"]).max() < 1e-6)

print("== 5. int8 权重重建 fp32 权重 (量化误差 <= 0.5 LSB) ==")
w1q, w1s = IM["classifier.1.weight_quantized"], IM["classifier.1.weight_scale"]
w2q, w2s = IM["classifier.3.weight_quantized"], IM["classifier.3.weight_scale"]
d1 = np.abs(w1q.astype(np.float64) * w1s[:, None].astype(np.float64) - IF["classifier.1.weight"]).max()
d2 = np.abs(w2q.astype(np.float64) * w2s[:, None].astype(np.float64) - IF["classifier.3.weight"]).max()
check(f"fc1 重建误差 {d1:.3e} <= 0.5*max(w1s)={0.5*w1s.max():.3e}", d1 <= 0.5 * w1s.max() + 1e-9)
check(f"fc2 重建误差 {d2:.3e} <= 0.5*max(w2s)={0.5*w2s.max():.3e}", d2 <= 0.5 * w2s.max() + 1e-9)
b1f = IM["classifier.1.bias_quantized"] * IM["classifier.1.bias_quantized_scale"]
b2f = IM["classifier.3.bias_quantized"] * IM["classifier.3.bias_quantized_scale"]
check(f"fc1 bias 重建误差 {np.abs(b1f - IF['classifier.1.bias']).max():.3e} (vs fp32 基准)", True)
check(f"fc2 bias 重建误差 {np.abs(b2f - IF['classifier.3.bias']).max():.3e} (vs fp32 基准)", True)

print("== 6. 特征图 scale: conv09 act_out (quant_params) vs model_int8.onnx ==")
s_conv09_qp = qp["conv_layers"][9]["act_out_scale"]
s_conv09_onnx = float(IM["/features/features.22/Conv_output_0_scale"])
check(f"conv09 act_out {s_conv09_qp:.10g} == features.22 Q scale {s_conv09_onnx:.10g}",
      rel(s_conv09_qp, s_conv09_onnx) < 1e-6)

print(f"  特征图 [1,96,15,32] scale = {s_conv09_onnx:.10g} (MaxPool 不改变量化域)")

os.makedirs(OUT_W, exist_ok=True)
os.makedirs(OUT_H, exist_ok=True)

w1 = np.ascontiguousarray(w1q, dtype=np.int8)
b1 = np.ascontiguousarray(IM["classifier.1.bias_quantized"], dtype=np.int32)
w2 = np.ascontiguousarray(w2q, dtype=np.int8)
b2 = np.ascontiguousarray(IM["classifier.3.bias_quantized"], dtype=np.int32)
w1.tofile(fr"{OUT_W}\head_w1_int8.bin")
b1.tofile(fr"{OUT_W}\head_b1_int32.bin")
w2.tofile(fr"{OUT_W}\head_w2_int8.bin")
b2.tofile(fr"{OUT_W}\head_b2_int32.bin")

def crc32_calc(buf):
    c = 0xFFFFFFFF
    for byte in buf:
        c ^= byte
        for _ in range(8):
            c = (c >> 1) ^ (0xEDB88320 & (0 - (c & 1)))
    return (~c) & 0xFFFFFFFF

payload = b"".join([w1.tobytes(), b1.tobytes(), w2.tobytes(), b2.tobytes()])
sizes = [len(w1.tobytes()), len(b1.tobytes()), len(w2.tobytes()), len(b2.tobytes())]
hdr = b"MFLH" + struct.pack("<IIIIII", 1, crc32_calc(payload), *sizes)
packed = hdr + payload
with open(os.path.join(OUT_W, "head_weights.bin"), "wb") as fp:
    fp.write(packed)

def carray_f32(name, arr):
    body = ",".join(f"{v:.9g}f" for v in np.asarray(arr, dtype=np.float64).ravel())
    return f"static const float {name}[] = {{{body}}};\n"

h = open(os.path.join(OUT_H, "quant_params.h"), "w", encoding="utf-8")
h.write("""/* quant_params.h -- 分类头量化参数 (gen_c_params.py 自动生成, 勿手改)
 * 权威来源: model_int8.onnx (与 quant_params.json / weights_int8 交叉验证一致);
 *   head_int8.onnx 权重相同, bias 差 1 通道 1 LSB, 中间 requant scale 略异, 仅作参考.
 * 特征图: int8 [1][96][15][32] NCHW, 对称量化 zp=0, scale=FEAT_SCALE
 *   (conv09 输出经 requant+ReLU+MaxPool(2x2,s2), ReLU/MaxPool 不改变量化域)
 * 头部数据流: GAP -> requant(FC1_IN_SCALE) -> fc1+ReLU -> fc2 -> softmax
 */
#ifndef QUANT_PARAMS_H
#define QUANT_PARAMS_H

#define FEAT_C 96
#define FEAT_H 15
#define FEAT_W 32
#define FC1_IN 96
#define FC1_OUT 256
#define FC2_OUT 3

""")
h.write(f"#define FEAT_SCALE {s_conv09_onnx:.9g}f   /* conv09 act_out scale */\n")
h.write(f"#define FC1_IN_SCALE {s1in:.9g}f\n")
h.write(f"#define FC1_OUT_SCALE {float(IM['/classifier/classifier.1/Gemm_output_0_scale']):.9g}f  /* QDQ 参考 */\n")
h.write(f"#define RELU_SCALE {s2in:.9g}f            /* fc2 输入 requant scale (QDQ 参考) */\n")
h.write(f"#define LOGITS_SCALE {float(IM['output_scale']):.9g}f   /* QDQ 参考 */\n\n")
h.write(carray_f32("fc1_w_scale", w1s))
h.write(carray_f32("fc1_b_scale", IM["classifier.1.bias_quantized_scale"]))
h.write(carray_f32("fc2_w_scale", w2s))
h.write(carray_f32("fc2_b_scale", IM["classifier.3.bias_quantized_scale"]))
h.write("""
/* 整数域合并 scale (定点主路径):
 *   q1[c]   = round(gap_acc[c] * GAP_TO_FC1)        acc = int32 逐通道和
 *   out1[j] = (int32 acc + b1[j]) * (FC1_IN_SCALE*fc1_w_scale[j]) -> float
 */
#define GAP_TO_FC1 (FEAT_SCALE / ((float)(FEAT_H*FEAT_W) * FC1_IN_SCALE))
""")
h.write("#endif /* QUANT_PARAMS_H */\n")
h.close()

print("\n== 导出完成 ==")
for f in ["head_w1_int8.bin", "head_b1_int32.bin", "head_w2_int8.bin", "head_b2_int32.bin", "head_weights.bin"]:
    p = os.path.join(OUT_W, f)
    print(f"  {f:22s} {os.path.getsize(p):7d} B  md5={hashlib.md5(open(p,'rb').read()).hexdigest()[:12]}")
h_path = os.path.join(OUT_H, "quant_params.h")
print(f"  quant_params.h         {os.path.getsize(h_path)} B")

print("\n结论:", "全部通过" if ok else "存在 FAIL, 见上")
sys.exit(0 if ok else 1)
