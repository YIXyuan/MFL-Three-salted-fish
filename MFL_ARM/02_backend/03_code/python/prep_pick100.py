import sys, io, os, posixpath, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
from PIL import Image
import onnx, onnxruntime as ort
from onnx import TensorProto, ValueInfoProto
import paramiko

L = r"D:\QianSai\new\arm_head"
R = r"D:\QianSai\new\arm_head\build\renamed_extract\renamed"
S = 0.1372978389
N = 100
ON_BOARD_DONE = {"P0011_001.jpg","P0047_001.jpg","P0053_001.jpg","P0071_001.jpg",
    "P0107_001.jpg","P1647_001.jpg","P0185_001.jpg","P0304_001.jpg","P0371_001.jpg",
    "P0549_001.jpg","P0736_001.jpg","P0868_001.jpg","P0924_001.jpg","P1241_001.jpg"}

allj = sorted(f for f in os.listdir(R) if f.lower().endswith(".jpg"))
cand = [f for f in allj if f not in ON_BOARD_DONE]
print(f"全集 {len(allj)}, 排除已处理后候选 {len(cand)}")
step = max(1, len(cand) // N)
pick = cand[::step][:N]
print(f"抽样 {len(pick)} 张 (步长 {step}): 首={pick[0]} 末={pick[-1]}")

EXP = r"D:\QianSai\new\quant_export(new)"
mi = onnx.load(fr"{EXP}\model_int8.onnx")
name_mp = "/features/features.24/MaxPool_output_0"
if name_mp not in {o.name for o in mi.graph.output}:
    vi = ValueInfoProto(); vi.name = name_mp
    vi.type.tensor_type.elem_type = TensorProto.FLOAT
    mi.graph.output.append(vi)
probe = os.path.join(L, "build", "pick3", "_p100.onnx"); onnx.save(mi, probe)
so = ort.SessionOptions(); so.intra_op_num_threads = 1
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
m8 = ort.InferenceSession(probe, so, providers=["CPUExecutionProvider"])
so2 = ort.SessionOptions(); so2.intra_op_num_threads = 1
hf = ort.InferenceSession(fr"{EXP}\head_fp32.onnx", so2, providers=["CPUExecutionProvider"])

ref = {}
t0 = time.time() if False else None
import time
t0 = time.time()
for i, fn in enumerate(pick, 1):
    img = Image.open(os.path.join(R, fn)).convert("RGB")
    if img.size != (1024, 480):
        print(f"  !! {fn} 尺寸 {img.size}, 剔除")
        continue
    a = np.asarray(img, dtype=np.float32) / 255.0
    q = np.clip(np.rint(a * 127.0), 0, 127).astype(np.int8)
    mp = m8.run([name_mp], {"input": (q.transpose(2, 0, 1)[None].astype(np.float32) / 127.0)})[0][0]
    feat = np.clip(np.rint(mp / S), -128, 127).astype(np.int8)
    lg = hf.run(["logits"], {"features": (feat.astype(np.float32) * S).reshape(1, 96, 15, 32)})[0][0]
    p = np.exp(lg - lg.max()); p /= p.sum()
    ref[fn] = {"pred": int(lg.argmax()), "probs": [float(x) for x in p],
               "point_id": fn.split("_")[0]}
    if i % 20 == 0:
        print(f"  参考 {i}/{len(pick)}  用时 {time.time()-t0:.0f}s")
os.remove(probe)
json.dump(ref, open(os.path.join(L, "build", "pick100_ref.json"), "w"))
from collections import Counter
dist = Counter(v["pred"] for v in ref.values())
print(f"参考完成 {len(ref)} 张, 用时 {time.time()-t0:.0f}s, 分布={dict(dist)}")

c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.1.10", username="root", password="${BOARD_PWD}", timeout=10,
          look_for_keys=False, allow_agent=False)
s = c.open_sftp()
existing = set(s.listdir("/root/sd_in"))
n_up = 0
for fn in ref:
    if fn in existing:
        print(f"  !! {fn} 已在 sd_in, 跳过")
        continue
    s.put(os.path.join(R, fn), posixpath.join("/root/sd_in", fn))
    n_up += 1
    if n_up % 25 == 0:
        print(f"  已上传 {n_up}")
s.close()
print(f"上传完成 {n_up} 张")
_, o, _ = c.exec_command("ls /root/sd_in | grep -c 'jpg$'", timeout=30)
print(f"sd_in 待处理 jpg: {o.read().decode().strip()}")
c.close()
