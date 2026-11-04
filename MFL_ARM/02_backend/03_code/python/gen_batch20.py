"""
"""
import sys, io, os, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
from PIL import Image
import onnx, onnxruntime as ort
from onnx import TensorProto, ValueInfoProto

EXPORT = r"D:\QianSai\new\quant_export(new)"
CAP = r"D:\QianSai\new\arm_head\build\mflweb_fork\MFL_Web_fork\data\captures"
OUT = r"D:\QianSai\new\arm_head\test_vectors\batch20"
os.makedirs(OUT, exist_ok=True)
S_FEAT = 0.1372978389263153

mi = onnx.load(fr"{EXPORT}\model_int8.onnx")
WANT = {
    "/features/features.22/Conv_output_0_QuantizeLinear_Output": TensorProto.INT8,
    "/features/features.24/MaxPool_output_0": TensorProto.FLOAT,
}
for name, et in WANT.items():
    if name not in {o.name for o in mi.graph.output}:
        vi = ValueInfoProto(); vi.name = name
        vi.type.tensor_type.elem_type = et
        mi.graph.output.append(vi)
probe = os.path.join(OUT, "_probe.onnx")
onnx.save(mi, probe)

so = ort.SessionOptions(); so.intra_op_num_threads = 1
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
m8 = ort.InferenceSession(probe, so, providers=["CPUExecutionProvider"])
so2 = ort.SessionOptions(); so2.intra_op_num_threads = 1
hf = ort.InferenceSession(fr"{EXPORT}\head_fp32.onnx", so2, providers=["CPUExecutionProvider"])

manifest = {"s_feat": S_FEAT, "source": "MFL_Web_fork data/captures", "cases": []}
files = sorted(f for f in os.listdir(CAP) if f.lower().endswith(".jpg"))
print(f"样例图: {len(files)} 张")

for fn in files:
    pid = fn.split("_")[0]
    img = Image.open(os.path.join(CAP, fn)).convert("RGB")
    if img.size != (1024, 480):
        img = img.resize((1024, 480), Image.BILINEAR)
    a = np.asarray(img, dtype=np.float32) / 255.0
    q = np.clip(np.rint(a * 127.0), 0, 127).astype(np.int8)
    chw = q.transpose(2, 0, 1)[None]

    xin = chw.astype(np.float32) / 127.0
    convq, mp_f = m8.run(list(WANT.keys()), {"input": xin})
    rq = np.maximum(convq[0], 0)
    feat15 = np.maximum(np.maximum(rq[:, 0::2, 0::2], rq[:, 0::2, 1::2]),
                        np.maximum(rq[:, 1::2, 0::2], rq[:, 1::2, 1::2])).reshape(96, 15, 32)

    gap = feat15.astype(np.float64).sum(axis=(1, 2)) * S_FEAT / 480.0
    feat4 = (feat15.astype(np.float32) * S_FEAT).reshape(1, 96, 15, 32)
    lg_f = hf.run(["logits"], {"features": feat4})[0][0]
    p = np.exp(lg_f - lg_f.max()); p /= p.sum()

    chw[0].tofile(os.path.join(OUT, f"{pid}_input_int8.bin"))
    feat15.astype(np.int8).tofile(os.path.join(OUT, f"{pid}_feat15_int8.bin"))
    convq[0].astype(np.int8).tofile(os.path.join(OUT, f"{pid}_feat30_int8.bin"))
    manifest["cases"].append({
        "image": fn, "point_id": pid,
        "input_file": f"{pid}_input_int8.bin",
        "feat15_file": f"{pid}_feat15_int8.bin",
        "logits_f32": [float(x) for x in lg_f],
        "probs_f32": [float(x) for x in p],
        "argmax_f32": int(lg_f.argmax()),
        "feat_min": int(feat15.min()), "feat_max": int(feat15.max()),
        "gap_max": float(gap.max()),
    })
    print(f"  {fn:16s} feat[{feat15.min():4d}..{feat15.max():4d}] gap_max={gap.max():.3f} "
          f"logits={np.array2string(lg_f, precision=3)} pred={int(lg_f.argmax())} "
          f"p={np.array2string(p, precision=3)}")

with open(os.path.join(OUT, "manifest_batch20.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)
os.remove(probe)

n = len(manifest["cases"])
from collections import Counter
dist = Counter(c["argmax_f32"] for c in manifest["cases"])
over = [c["point_id"] for c in manifest["cases"] if c["gap_max"] > 0.85]
print(f"\n完成 {n} 张; pred 分布={dict(dist)}; GAP>0.85(q1 饱和区): {over if over else '无'}")
print(f"输出目录: {OUT}")
