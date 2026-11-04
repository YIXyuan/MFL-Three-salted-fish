import sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import onnx, onnxruntime as ort

EXPORT = r"D:\QianSai\new\quant_export(new)"
TV = r"D:\QianSai\new\arm_head\test_vectors"

mi = onnx.load(fr"{EXPORT}\model_int8.onnx")
WANT = {
    "/features/features.22/Conv_output_0_QuantizeLinear_Output": onnx.TensorProto.INT8,
    "/features/features.24/MaxPool_output_0": onnx.TensorProto.FLOAT,
    "/classifier/classifier.0/Flatten_output_0_QuantizeLinear_Output": onnx.TensorProto.INT8,
    "/classifier/classifier.1/Gemm_output_0": onnx.TensorProto.FLOAT,
    "/classifier/classifier.1/Gemm_output_0_QuantizeLinear_Output": onnx.TensorProto.INT8,
    "/classifier/classifier.2/Relu_output_0": onnx.TensorProto.FLOAT,
    "/classifier/classifier.2/Relu_output_0_QuantizeLinear_Output": onnx.TensorProto.INT8,
    "output": onnx.TensorProto.FLOAT,
}
for name, et in WANT.items():
    if name not in {o.name for o in mi.graph.output}:
        vi = onnx.ValueInfoProto(); vi.name = name
        vi.type.tensor_type.elem_type = et
        mi.graph.output.append(vi)
probe = fr"{TV}\_probe2.onnx"
onnx.save(mi, probe)
so = ort.SessionOptions()
so.intra_op_num_threads = 1
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
sess = ort.InferenceSession(probe, so, providers=["CPUExecutionProvider"])

IM = {t.name: onnx.numpy_helper.to_array(t) for t in mi.graph.initializer}
S_FEAT = 0.1372978389263153
S1IN = float(IM["/classifier/classifier.0/Flatten_output_0_scale"])
S1OUT = float(IM["/classifier/classifier.1/Gemm_output_0_scale"])
S2IN = float(IM["/classifier/classifier.2/Relu_output_0_scale"])
SLOG = float(IM["output_scale"])
W1 = IM["classifier.1.weight_quantized"].astype(np.int32)
WS1 = IM["classifier.1.weight_scale"]
B1 = IM["classifier.1.bias_quantized"]
BS1 = IM["classifier.1.bias_quantized_scale"]
W2 = IM["classifier.3.weight_quantized"].astype(np.int32)
WS2 = IM["classifier.3.weight_scale"]
B2 = IM["classifier.3.bias_quantized"]
BS2 = IM["classifier.3.bias_quantized_scale"]

def q(x, s):
    return np.clip(np.rint(x / s), -128, 127).astype(np.int8)

def rne(x):
    return np.rint(x).astype(np.int32)

for case in ["zeros", "zeros2"]:

    img = np.zeros((1, 3, 480, 1024), dtype=np.float32)
    outs = sess.run(list(WANT.keys()), {"input": img})
    (convq, mp_f, q1_ref, fc1_ref, qy_ref, relu_ref, q2_ref, out_ref) = outs

    rq = np.maximum(convq[0], 0)
    mp8 = np.maximum(np.maximum(rq[:, 0::2, 0::2], rq[:, 0::2, 1::2]),
                     np.maximum(rq[:, 1::2, 0::2], rq[:, 1::2, 1::2])).reshape(96, -1)
    gap = mp8.astype(np.int64).sum(1).astype(np.float32) * S_FEAT / 480.0
    q1 = q(gap.reshape(1, 96), S1IN)
    print(f"\n[{case}] q1 一致: {np.array_equal(q1, q1_ref)} 不同 {int((q1 != q1_ref).sum())}/96 "
          f"q1范围[{q1.min()},{q1.max()}] 饱和={int((np.abs(q1_ref)==127).sum())}")

    x_dq = q1.astype(np.float32) * S1IN
    w_dq = W1.astype(np.float32) * WS1[:, None]
    y = x_dq @ w_dq.T + (B1.astype(np.float64) * BS1).astype(np.float32)[None, :]
    print(f"  fc1 float 一致: max|Δ|={np.abs(y-fc1_ref).max():.4g}  "
          f"范围[{fc1_ref.min():.3f},{fc1_ref.max():.3f}]")
    qy = q(y, S1OUT)
    print(f"  q(fc1) 一致: {np.array_equal(qy, qy_ref)} 不同 {int((qy != qy_ref).sum())}/256")

    acc = q1.astype(np.int32) @ W1.T + B1[None, :]
    y2 = acc.astype(np.float32) * (S1IN * WS1)[None, :]
    print(f"  int32路径 vs float路径: max|Δ|={np.abs(y2-y).max():.4g}")

    relu_dq = np.maximum(qy.astype(np.float32) * S1OUT, 0)
    print(f"  relu 一致: max|Δ|={np.abs(relu_dq-relu_ref).max():.4g}")
    q2 = q(relu_dq, S2IN)
    print(f"  q2 一致: {np.array_equal(q2, q2_ref)} 不同 {int((q2 != q2_ref).sum())}/256")

    acc2 = q2.astype(np.int32) @ W2.T + B2[None, :]
    lg = acc2.astype(np.float32) * (S2IN * WS2)[None, :]
    lg = np.rint(lg / SLOG) * SLOG
    print(f"  logits 一致: max|Δ|={np.abs(lg-out_ref).max():.4g}  ours={lg[0]} ref={out_ref[0]}")
