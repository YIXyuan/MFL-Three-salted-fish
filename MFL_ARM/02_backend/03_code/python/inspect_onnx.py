import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
import numpy as np
import onnx
from onnx import numpy_helper

EXPORT = r"D:\QianSai\new\quant_export(new)"

def elem_str(t):
    return {1: "float32", 2: "uint8", 3: "int8", 4: "uint16", 5: "int16", 6: "int32",
            7: "int64", 9: "bool", 11: "double"}.get(t, str(t))

def dump_io(model, title):
    print(f"\n=== {title}: 图输入/输出 ===")
    for vi, tag in [(i, "IN ") for i in model.graph.input] + [(o, "OUT") for o in model.graph.output]:
        tt = vi.type.tensor_type
        dims = [d.dim_value if d.HasField("dim_value") else d.dim_param for d in tt.shape.dim]
        print(f"  {tag} {vi.name:30s} {elem_str(tt.elem_type):8s} {dims}")

def dump_nodes(model, title):
    print(f"\n=== {title}: 节点 ===")
    for i, n in enumerate(model.graph.node):
        print(f"  [{i:2d}] {n.op_type:20s} {n.name}")
        print(f"        inputs : {list(n.input)}")
        print(f"        outputs: {list(n.output)}")
        for a in n.attribute:
            print(f"        attr {a.name} = {onnx.helper.get_attribute_value(a)}")

def dump_init(model, title, detail=True):
    print(f"\n=== {title}: 初始化器 (权重/参数) ===")
    for init in model.graph.initializer:
        arr = numpy_helper.to_array(init)
        if arr.size <= 8 or detail:
            preview = np.array2string(arr.ravel()[:8], precision=8)
        else:
            preview = ""
        print(f"  {init.name:34s} {elem_str(init.data_type):8s} {str(list(arr.shape)):18s} "
              f"min={arr.min():+.6g} max={arr.max():+.6g} mean={arr.mean():+.6g}  {preview}")

def dump_value_info(model, title):
    if not model.graph.value_info:
        return
    print(f"\n=== {title}: 中间张量形状 ===")
    for vi in model.graph.value_info:
        tt = vi.type.tensor_type
        dims = [d.dim_value if d.HasField("dim_value") else d.dim_param for d in tt.shape.dim]
        print(f"  {vi.name:34s} {elem_str(tt.elem_type):8s} {dims}")

m = onnx.load(fr"{EXPORT}\head_int8.onnx")
dump_io(m, "head_int8.onnx")
dump_nodes(m, "head_int8.onnx")
dump_init(m, "head_int8.onnx")
dump_value_info(m, "head_int8.onnx")

m = onnx.load(fr"{EXPORT}\head_fp32.onnx")
dump_io(m, "head_fp32.onnx")
dump_nodes(m, "head_fp32.onnx")
dump_init(m, "head_fp32.onnx")

for name in ["model_fp32_fused.onnx", "model_int8.onnx"]:
    mm = onnx.load(fr"{EXPORT}\{name}")
    dump_io(mm, name)
    dump_nodes(mm, name)
    mm2 = onnx.shape_inference.infer_shapes(mm)
    dump_value_info(mm2, name + " (shape_inferred)")
