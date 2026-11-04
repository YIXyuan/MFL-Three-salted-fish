import sys, io, os, posixpath
import paramiko, numpy as np
import onnx, onnxruntime as ort
from onnx import TensorProto, ValueInfoProto

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
H, U, P = "192.168.1.10", "root", "${BOARD_PWD}"
L = r"D:\QianSai\new\arm_head"
OUTL = os.path.join(L, "build", "first_frame")
os.makedirs(OUTL, exist_ok=True)
S = 0.1372978389

c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(H, username=U, password=P, timeout=10, look_for_keys=False, allow_agent=False)
s = c.open_sftp()
s.put(os.path.join(L, "build", "dump_out_arm"), "/root/head_test/dump_out")
s.close()
def run(cmd, t=120):
    _, o, e = c.exec_command(cmd, timeout=t)
    out = o.read().decode("utf-8", "replace").rstrip()
    err = e.read().decode("utf-8", "replace").rstrip()
    if out: print(out)
    if err: print("[stderr]", err)
run("chmod +x /root/head_test/dump_out && cd /root/head_test && ./dump_out /tmp/out.bin && ls -l /tmp/out.bin && md5sum /tmp/out.bin")
s = c.open_sftp()
s.get("/tmp/out.bin", os.path.join(OUTL, "out.bin"))
s.close()
c.close()
print(f"下载: {os.path.getsize(os.path.join(OUTL,'out.bin')):,} B")

fpga = np.fromfile(os.path.join(OUTL, "out.bin"), dtype=np.int8)
print(f"FPGA OUT: min={fpga.min()} max={fpga.max()} 全零通道={int((fpga.reshape(96,-1)==0).all(1).sum())}")

EXP = r"D:\QianSai\new\quant_export(new)"
q = np.fromfile(os.path.join(L, "test_vectors", "real", "P0001_001.input_int8.bin"), dtype=np.int8)
x = (q.astype(np.float32) / 127.0).reshape(1, 3, 480, 1024)
mi = onnx.load(fr"{EXP}\model_int8.onnx")
name = "/features/features.24/MaxPool_output_0"
if name not in {o.name for o in mi.graph.output}:
    vi = ValueInfoProto(); vi.name = name; vi.type.tensor_type.elem_type = TensorProto.FLOAT
    mi.graph.output.append(vi)
probe = os.path.join(OUTL, "_p.onnx"); onnx.save(mi, probe)
so = ort.SessionOptions(); so.intra_op_num_threads = 1
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
mp = ort.InferenceSession(probe, so, providers=["CPUExecutionProvider"]).run([name], {"input": x})[0][0]
ref = np.clip(np.rint(mp / S), -128, 127).astype(np.int8).reshape(-1)
os.remove(probe)
print(f"PC  参考: min={ref.min()} max={ref.max()} 全零通道={int((ref.reshape(96,-1)==0).all(1).sum())}")

d = np.abs(fpga.astype(np.int32) - ref.astype(np.int32))
print(f"\n逐元素: 相同 {100*(d==0).mean():.2f}%  |Δ|<=1 {100*(d<=1).mean():.2f}%  max|Δ|={d.max()}")
print(f"通道级: 全同 {int((d.reshape(96,-1).max(1)==0).sum())}/96, "
      f"|Δ|<=1 {int((d.reshape(96,-1).max(1)<=1).sum())}/96")

so2 = ort.SessionOptions(); so2.intra_op_num_threads = 1
hf = ort.InferenceSession(fr"{EXP}\head_fp32.onnx", so2, providers=["CPUExecutionProvider"])
def head(feat):
    f = feat.astype(np.float32) * S
    lg = hf.run(["logits"], {"features": f.reshape(1,96,15,32)})[0][0]
    p = np.exp(lg-lg.max()); p/=p.sum()
    return lg, p
lg_f, p_f = head(fpga)
lg_r, p_r = head(ref)
print(f"\nFPGA OUT 头: logits={np.array2string(lg_f,precision=4)} probs={np.array2string(p_f,precision=4)} pred={int(lg_f.argmax())}")
print(f"PC 参考头 : logits={np.array2string(lg_r,precision=4)} probs={np.array2string(p_r,precision=4)} pred={int(lg_r.argmax())}")
print(f"logits max|Δ| = {np.abs(lg_f-lg_r).max():.4f}")
