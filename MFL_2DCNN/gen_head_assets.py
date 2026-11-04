#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_head_assets.py —— 从 model_int8.onnx 提取 ARM 定点头资产(最小 ONNX 解析器, 零依赖)
产出:
  weights/mfl_head.bin   fc1_w(int8 256x96) + fc1_bq(int32 256) +
                         fc2_w(int8 3x256)  + fc2_bq(int32 3)   [固定布局]
  head_params.h          全部 scale 常量 + w_scale 数组 + bin 偏移
交叉验证(全部通过才写出文件):
  1) onnx 尾部节点序 == 预期 QDQ 链
  2) 各 Q scale 与 output/quant_export/quant_params.json 逐项一致
  3) GAP 输入 scale(conv09 out) 双源一致: onnx /features.22/Conv_output_0_scale
     == json conv_layers[9].act_out_scale
  4) bias_scale ≈ act_in_scale * w_scale[c] (合并公式成立), 所有 zero_point == 0
用法: python3 tools/gen_head_assets.py [model_int8.onnx] [quant_params.json] [输出目录]
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np

DT = {1: 'float32', 2: 'uint8', 3: 'int8', 6: 'int32', 7: 'int64',
      10: 'float16', 11: 'float64'}


def read_varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def parse_fields(buf):
    pos, out = 0, []
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        fno, wt = key >> 3, key & 7
        if wt == 0:
            val, pos = read_varint(buf, pos)
        elif wt == 2:
            ln, pos = read_varint(buf, pos)
            val = buf[pos:pos + ln]
            pos += ln
        elif wt == 5:
            val = struct.unpack('<f', buf[pos:pos + 4])[0]
            pos += 4
        elif wt == 1:
            val = struct.unpack('<d', buf[pos:pos + 8])[0]
            pos += 8
        else:
            raise ValueError(f'wiretype {wt}')
        out.append((fno, wt, val))
    return out


def tensor_array(t):
    dt = DT[t['dtype']]
    if t['raw'] is not None:
        arr = np.frombuffer(t['raw'], dtype=dt)
    elif t['float_data']:
        arr = np.array(t['float_data'], dtype='float32')
    elif t['int32_data']:
        arr = np.array(t['int32_data'], dtype='int32')
    else:
        arr = np.zeros(0, dtype=dt)
    dims = t['dims']
    expect = 1
    for d in dims:
        expect *= d
    if arr.size != expect:                 # 空数据/占位 initializer
        arr = np.zeros(expect, dtype=dt)
    return arr.reshape(dims) if dims else (arr.reshape([]) if arr.size else arr)


def load_onnx(path):
    buf = Path(path).read_bytes()
    graph = [v for f, w, v in parse_fields(buf) if f == 7][0]
    inits, nodes = {}, []
    for fno, wt, val in parse_fields(graph):
        if fno == 5:                       # TensorProto
            t = {'dims': [], 'dtype': 0, 'raw': None,
                 'float_data': [], 'int32_data': []}
            name = b''
            for f2, w2, v2 in parse_fields(val):
                if f2 == 1 and w2 == 0:
                    t['dims'].append(v2)
                elif f2 == 1 and w2 == 2:
                    p = 0
                    while p < len(v2):
                        d, p = read_varint(v2, p)
                        t['dims'].append(d)
                elif f2 == 2 and w2 == 0:
                    t['dtype'] = v2
                elif f2 == 4 and w2 == 2 and len(v2) % 4 == 0:
                    t['float_data'] = list(struct.unpack(f'<{len(v2)//4}f', v2))
                elif f2 == 5 and w2 == 2 and len(v2) % 4 == 0:
                    t['int32_data'] = list(struct.unpack(f'<{len(v2)//4}i', v2))
                elif f2 == 8 and w2 == 2:
                    name = v2
                elif f2 == 9 and w2 == 2:
                    t['raw'] = v2
            inits[name.decode()] = tensor_array(t)
        elif fno == 1:                      # NodeProto
            n = {'inputs': [], 'outputs': [], 'op': ''}
            for f2, w2, v2 in parse_fields(val):
                if f2 == 1 and w2 == 2:
                    n['inputs'].append(v2.decode())
                elif f2 == 2 and w2 == 2:
                    n['outputs'].append(v2.decode())
                elif f2 == 4 and w2 == 2:
                    n['op'] = v2.decode()
            nodes.append(n)
    return inits, nodes


def arr_c(name, values):
    vals = ', '.join(f'{v:.9g}f' for v in np.ravel(values).astype(np.float64))
    return f'static const float {name}[{np.size(values)}] = {{{vals}}};'


def main():
    onnx = Path(sys.argv[1] if len(sys.argv) > 1 else
                '/home/z/my-project/mfl2d_v2/output_new/quant_export/model_int8.onnx')
    qp_path = Path(sys.argv[2] if len(sys.argv) > 2 else
                   '/home/z/my-project/mfl2d_v2/output_new/quant_export/quant_params.json')
    out_dir = Path(sys.argv[3] if len(sys.argv) > 3 else
                   Path(__file__).resolve().parent.parent)

    inits, nodes = load_onnx(onnx)
    qp = json.loads(qp_path.read_text(encoding='utf-8'))
    print(f'[读入] {onnx.name}: {len(nodes)} nodes, {len(inits)} inits')

    # ---- 校验 1: 尾部 QDQ 链 ----
    expect = ['Relu', 'MaxPool', 'GlobalAveragePool', 'Flatten',
              'QuantizeLinear', 'DequantizeLinear', 'Gemm',
              'QuantizeLinear', 'DequantizeLinear', 'Relu',
              'QuantizeLinear', 'DequantizeLinear', 'Gemm',
              'QuantizeLinear', 'DequantizeLinear']
    tail = [n['op'] for n in nodes[-len(expect):]]
    assert tail == expect, f'onnx 尾部结构与预期不符: {tail}'
    # conv09 之后无再量化: Relu(23)/MaxPool(24) 后直接 GAP
    assert '/features/features.23/Relu_output_0_scale' not in inits
    assert '/features/features.24/MaxPool_output_0_scale' not in inits
    print('[校验1] 尾部 QDQ 链符合预期; conv09 后 relu/pool 无再量化(GAP 输入 scale=conv09 out)')

    # ---- 提取 ----
    w1 = inits['classifier.1.weight_quantized']        # int8 [256,96]
    w1s = np.ravel(inits['classifier.1.weight_scale']).astype(np.float64)
    bq1 = np.ravel(inits['classifier.1.bias_quantized'])           # int32 [256]
    b1s = np.ravel(inits['classifier.1.bias_quantized_scale']).astype(np.float64)
    w2 = inits['classifier.3.weight_quantized']        # int8 [3,256]
    w2s = np.ravel(inits['classifier.3.weight_scale']).astype(np.float64)
    bq2 = np.ravel(inits['classifier.3.bias_quantized'])           # int32 [3]
    b2s = np.ravel(inits['classifier.3.bias_quantized_scale']).astype(np.float64)

    s_feat = float(inits['/features/features.22/Conv_output_0_scale'])   # GAP 输入
    s_f1in = float(inits['/classifier/classifier.0/Flatten_output_0_scale'])
    s_f1out = float(inits['/classifier/classifier.1/Gemm_output_0_scale'])
    s_f2in = float(inits['/classifier/classifier.2/Relu_output_0_scale'])
    s_f2out = float(inits['output_scale'])

    # ---- 校验 2/3: 与 quant_params.json 对拍 ----
    def close(a, b, tol=1e-6):
        return abs(a - b) <= tol * max(1.0, abs(a))
    assert close(s_feat, qp['conv_layers'][9]['act_out_scale']), 'conv09 out scale 不一致'
    assert close(s_f1in, qp['head_layers'][0]['act_in_scale']), 'fc1 in scale 不一致'
    assert close(s_f1out, qp['head_layers'][0]['act_out_scale']), 'fc1 out scale 不一致'
    assert close(s_f2in, qp['head_layers'][1]['act_in_scale']), 'fc2 in scale 不一致'
    assert close(s_f2out, qp['head_layers'][1]['act_out_scale']), 'fc2 out scale 不一致'
    assert np.allclose(w1s, np.ravel(qp['head_layers'][0]['weight_scale']), rtol=1e-5)
    assert np.allclose(w2s, np.ravel(qp['head_layers'][1]['weight_scale']), rtol=1e-5)
    assert w1.shape == (256, 96) and w2.shape == (3, 256)
    print('[校验2] 5 个 scale + 2 组 w_scale 与 quant_params.json 逐项一致')

    # ---- 校验 4: bias 合并公式 + 对称量化 ----
    assert np.allclose(b1s, s_f1in * w1s, rtol=2e-7)
    assert np.allclose(b2s, s_f2in * w2s, rtol=2e-7)
    assert not np.any(inits['classifier.1.weight_zero_point'])
    assert not np.any(inits['classifier.1.bias_quantized_zero_point'])
    assert not np.any(inits['classifier.3.weight_zero_point'])
    assert not np.any(inits['classifier.3.bias_quantized_zero_point'])
    print('[校验4] bias_scale==s_in*w_scale(合并公式成立), 所有 zero_point=0')

    # ---- 写 mfl_head.bin (固定布局) ----
    wdir = out_dir / 'weights'
    wdir.mkdir(parents=True, exist_ok=True)
    offs = [0, 256 * 96, 256 * 96 + 256 * 4, 256 * 96 + 256 * 4 + 3 * 256]
    total = offs[-1] + 3 * 4
    blob = (np.ascontiguousarray(w1, dtype=np.int8).tobytes()
            + np.ascontiguousarray(bq1, dtype=np.int32).tobytes()
            + np.ascontiguousarray(w2, dtype=np.int8).tobytes()
            + np.ascontiguousarray(bq2, dtype=np.int32).tobytes())
    assert len(blob) == total
    (wdir / 'mfl_head.bin').write_bytes(blob)
    print(f'[写出] {wdir / "mfl_head.bin"} ({total} B; '
          f'fc1_w@{offs[0]} fc1_bq@{offs[1]} fc2_w@{offs[2]} fc2_bq@{offs[3]})')

    # ---- 写 head_params.h ----
    gap_k = s_feat / (480.0 * s_f1in)
    # ---- 写 head_params.json (sidecar: 数值工具/参考实现与 C 共用同一组数) ----
    (out_dir / 'head_params.json').write_text(json.dumps({
        's_feat': s_feat, 's_fc1_in': s_f1in, 's_fc1_out': s_f1out,
        's_fc2_in': s_f2in, 's_fc2_out': s_f2out, 'gap_k': gap_k,
        'fc1_w_scale': w1s.tolist(), 'fc2_w_scale': w2s.tolist(),
        'bin': 'weights/mfl_head.bin', 'bin_size': total,
        'offsets': {'fc1_w': offs[0], 'fc1_bq': offs[1],
                    'fc2_w': offs[2], 'fc2_bq': offs[3]},
        'source': str(onnx), 'verified_against': str(qp_path),
    }, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f'[写出] {out_dir / "head_params.json"}')

    hpp = out_dir / 'head_params.h'
    hpp.write_text(
        '/* 自动生成: tools/gen_head_assets.py <- model_int8.onnx (经 quant_params.json 对拍)\n'
        '   勿手改。GEMM 数据流(与 SPEC 第4节一致):\n'
        '   q1 = clamp(round(sum * GAP_K))            GAP: sum=Σfeat(480), GAP_K=S_FEAT/(480*S_FC1_IN)\n'
        '   acc32 = Σ q1[k]*w[c][k] + bq[c]           (bias 合并: bias_scale==S_FC1_IN*w_scale[c])\n'
        '   q2 = clamp(round(acc*S_FC1_IN*w_scale[c]/S_FC1_OUT)); ReLU: q2=max(q2,0)\n'
        '   同理 fc2; logits = ql*S_FC2_OUT (反量化) */\n'
        '#ifndef MFL_HEAD_PARAMS_H\n#define MFL_HEAD_PARAMS_H\n\n'
        '#define MFL_FEAT_CH 96\n#define MFL_FEAT_H 15\n#define MFL_FEAT_W 32\n'
        '#define MFL_FC1_OUT 256\n#define MFL_NUM_CLASSES 3\n\n'
        '/* feature map(GAP 输入, 即 FPGA 交付物) scale = conv09 act_out;\n'
        '   链路: conv09→Q(S_FEAT)→ReLU→MaxPool→GAP (relu/pool 不改变 scale) */\n'
        f'#define MFL_S_FEAT    {s_feat:.9g}f\n'
        f'#define MFL_S_FC1_IN  {s_f1in:.9g}f\n'
        f'#define MFL_S_FC1_OUT {s_f1out:.9g}f\n'
        f'#define MFL_S_FC2_IN  {s_f2in:.9g}f\n'
        f'#define MFL_S_FC2_OUT {s_f2out:.9g}f\n\n'
        f'#define MFL_GAP_K     {gap_k:.9g}f\n\n'
        '/* mfl_head.bin 布局 */\n'
        f'#define MFL_HEAD_FC1_W_OFF {offs[0]}\n'
        f'#define MFL_HEAD_FC1_B_OFF {offs[1]}\n'
        f'#define MFL_HEAD_FC2_W_OFF {offs[2]}\n'
        f'#define MFL_HEAD_FC2_B_OFF {offs[3]}\n'
        f'#define MFL_HEAD_BIN_SIZE  {total}\n\n'
        + arr_c('mfl_fc1_w_scale', w1s) + '\n'
        + arr_c('mfl_fc2_w_scale', w2s) + '\n\n'
        '#endif /* MFL_HEAD_PARAMS_H */\n', encoding='utf-8')
    print(f'[写出] {hpp}')


if __name__ == '__main__':
    main()
