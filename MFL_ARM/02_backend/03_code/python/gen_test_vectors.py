"""
"""
import sys, io, json, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import onnx
import onnxruntime as ort

EXPORT = r"D:\QianSai\new\quant_export(new)"
TV = r"D:\QianSai\new\arm_head\test_vectors"
os.makedirs(TV, exist_ok=True)

WANT = {
    "/features/features.22/Conv_output_0_QuantizeLinear_Output": onnx.TensorProto.INT8,
    "/features/features.24/MaxPool_output_0": onnx.TensorProto.FLOAT,
    "/classifier/classifier.1/Gemm_output_0": onnx.TensorProto.FLOAT,
    "/classifier/classifier.2/Relu_output_0": onnx.TensorProto.FLOAT,
}
mi = onnx.load(fr"{EXPORT}\model_int8.onnx")
existing = {o.name for o in mi.graph.output}
for name, etype in WANT.items():
    if name in existing:
        continue
    vi = onnx.ValueInfoProto()
    vi.name = name
    vi.type.tensor_type.elem_type = etype
    mi.graph.output.append(vi)
probe_path = os.path.join(TV, "_probe_model_int8.onnx")
onnx.save(mi, probe_path)

so = ort.SessionOptions()
so.intra_op_num_threads = 1
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
m8 = ort.InferenceSession(probe_path, so, providers=["CPUExecutionProvider"])
m8_out_names = [o.name for o in m8.get_outputs()]
hf = ort.InferenceSession(fr"{EXPORT}\head_fp32.onnx", so, providers=["CPUExecutionProvider"])

rng = np.random.default_rng(20260917)

cases = []
cases.append(("normal", rng.uniform(0.0, 0.5, size=(1, 3, 480, 1024)).astype(np.float32)))
cases.append(("zeros", np.zeros((1, 3, 480, 1024), dtype=np.float32)))
cases.append(("bright", np.full((1, 3, 480, 1024), 1.0, dtype=np.float32)))
for i in range(12):
    lo, hi = [(0.0, 0.3), (0.0, 0.8), (0.4, 1.0), (0.0, 1.0)][i % 4]
    cases.append((f"rand{i:02d}", rng.uniform(lo, hi, size=(1, 3, 480, 1024)).astype(np.float32)))

S_FEAT = 0.1372978389263153

manifest = {"s_feat": S_FEAT, "cases": []}
for name, img in cases:
    outs = m8.run(["/features/features.22/Conv_output_0_QuantizeLinear_Output",
                   "/features/features.24/MaxPool_output_0",
                   "/classifier/classifier.1/Gemm_output_0",
                   "/classifier/classifier.2/Relu_output_0",
                   "output"], {"input": img})
    assert len(outs) == 5
    conv_q, mp_f, fc1, relu, lg8 = outs

    assert conv_q.dtype == np.int8 and conv_q.shape == (1, 96, 30, 64)
    rq = np.maximum(conv_q[0], 0)
    mp8 = np.maximum(np.maximum(rq[:, 0::2, 0::2], rq[:, 0::2, 1::2]),
                     np.maximum(rq[:, 1::2, 0::2], rq[:, 1::2, 1::2]))

    feat_fq = mp_f
    delta = np.abs(mp8.astype(np.float32) * S_FEAT - feat_fq[0]).max()
    assert delta < 1e-5, f"int8/float 特征图不等价: {delta}"
    feat8 = mp8.reshape(1, 96, 15, 32)
    lg_f = hf.run(["logits"], {"features": feat_fq})[0][0]

    gap = feat_fq.mean(axis=(2, 3))[0]

    base = fr"{TV}\{name}"
    feat8.astype(np.int8).tofile(base + "_feat_int8.bin")
    rq.astype(np.int8).tofile(base + "_feat30_int8.bin")
    lg_f.astype(np.float32).tofile(base + "_logits_f32.bin")
    lg8[0].astype(np.float32).tofile(base + "_logits_int8.bin")
    gap.astype(np.float32).tofile(base + "_gap_f32.bin")
    fc1[0].astype(np.float32).tofile(base + "_fc1_f32.bin")
    relu[0].astype(np.float32).tofile(base + "_relu_f32.bin")
    manifest["cases"].append({
        "name": name,
        "feat_file": f"{name}_feat_int8.bin",
        "logits_f32": [float(x) for x in lg_f],
        "logits_int8": [float(x) for x in lg8[0]],
        "argmax_f32": int(lg_f.argmax()),
        "argmax_int8": int(lg8[0].argmax()),
        "feat_min": int(feat8.min()), "feat_max": int(feat8.max()),
    })
    print(f"  {name:8s} feat[{feat8.min():4d}..{feat8.max():4d}] "
          f"logits_f32={np.array2string(lg_f, precision=4)} argmax={lg_f.argmax()} "
          f"| lg_int8={np.array2string(lg8[0], precision=4)}")

with open(fr"{TV}\manifest_head.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)
print(f"\n向量已写入 {TV} ({len(manifest['cases'])} 案例)")
