#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
head_ref_check.py —— head.c 的 numpy 镜像参考实现(与 C 完全同公式同 float32 顺序)
生成 tests/data/head_synth_feat.bin + head_synth_expect.txt 供 test_head 比对;
也可对真实 conv09_out_int8.npy 计算(等 C 的 --from-conv09 口径), 用于 M1 对拍。

用法:
  python3 tools/head_ref_check.py                        # 合成向量(固定种子)
  python3 tools/head_ref_check.py <conv09_out.npy>       # 真实 conv09 输出(npy)
输出(合成模式): feat/期望 logits 写 tests/data/; 真实模式只打印期望值。
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
P = json.loads((ROOT / 'head_params.json').read_text(encoding='utf-8'))
blob = np.frombuffer((ROOT / 'weights' / 'mfl_head.bin').read_bytes(), dtype=np.uint8)
fc1_w = np.frombuffer(blob[P['offsets']['fc1_w']:].tobytes(), dtype=np.int8,
                      count=256 * 96).reshape(256, 96)
fc1_bq = np.frombuffer(blob[P['offsets']['fc1_bq']:].tobytes(), dtype=np.int32, count=256)
fc2_w = np.frombuffer(blob[P['offsets']['fc2_w']:].tobytes(), dtype=np.int8,
                      count=3 * 256).reshape(3, 256)
fc2_bq = np.frombuffer(blob[P['offsets']['fc2_bq']:].tobytes(), dtype=np.int32, count=3)

f32 = np.float32
S_FEAT, S1I, S1O, S2I, S2O = (f32(P['s_feat']), f32(P['s_fc1_in']),
                               f32(P['s_fc1_out']), f32(P['s_fc2_in']),
                               f32(P['s_fc2_out']))
W1S = np.array(P['fc1_w_scale'], dtype=np.float32)
W2S = np.array(P['fc2_w_scale'], dtype=np.float32)
GAP_K = f32(P['gap_k'])
RELU_REQ_K = f32(S1O / S2I)   # v3: head.c 的 fc1_out→fc2_in 中间再量化


def head_forward(feat_i8):
    """feat: int8 (96,15,32) → (logits, probs, argmax); 镜像 head.c 的 float32 顺序。"""
    s = feat_i8.reshape(96, -1).astype(np.int32).sum(axis=1)     # GAP int32
    q1 = np.clip(np.rint(s.astype(np.float32) * GAP_K), -128, 127).astype(np.int32)
    acc = q1 @ fc1_w.T.astype(np.int32) + fc1_bq                 # (256,)
    y = acc.astype(np.float32) * (S1I * W1S)                     # (256,)
    q2 = np.clip(np.rint(y / S1O), -128, 127)
    q2 = np.maximum(q2, 0).astype(np.int32)                      # ReLU
    q2 = np.clip(np.rint(q2.astype(np.float32) * RELU_REQ_K), -128, 127).astype(np.int32)  # v3 中间再量化
    acc2 = q2 @ fc2_w.T.astype(np.int32) + fc2_bq                # (3,)
    y2 = acc2.astype(np.float32) * (S2I * W2S)
    ql = np.clip(np.rint(y2 / S2O), -128, 127).astype(np.int32)
    logits = ql.astype(np.float32) * S2O
    e = np.exp(logits - logits.max())
    probs = e / e.sum()
    return logits, probs, int(np.argmax(logits))


def relu_pool5(conv09):
    """int8 域 relu+maxpool2x2, (96,30,64)→(96,15,32); 与 mfl_relu_pool5 等价。"""
    x = np.maximum(conv09.reshape(96, 30, 64), 0)
    x = x.reshape(96, 15, 2, 32, 2).max(axis=(2, 4))
    return np.ascontiguousarray(x)


def main():
    if len(sys.argv) >= 2:                                        # 真实 conv09 模式
        c9 = np.load(sys.argv[1])
        assert c9.dtype == np.int8 and c9.shape == (96, 30, 64), (c9.dtype, c9.shape)
        feat = relu_pool5(c9)
        logits, probs, am = head_forward(feat)
        print('expect logits :', ' '.join(f'{v:.6f}' for v in logits))
        print('expect softmax:', ' '.join(f'{v:.6f}' for v in probs))
        print('expect argmax :', am, f'({["normal","light","severe"][am]})')
        return

    rng = np.random.default_rng(2026)                             # 合成模式
    feat = rng.integers(-40, 80, (96, 15, 32), dtype=np.int8)
    logits, probs, am = head_forward(feat)

    d = ROOT / 'tests' / 'data'
    d.mkdir(parents=True, exist_ok=True)
    feat.tofile(d / 'head_synth_feat.bin')
    with open(d / 'head_synth_expect.txt', 'w', encoding='utf-8') as f:
        f.write(' '.join(f'{v:.6f}' for v in logits) + '\n')
        f.write(' '.join(f'{v:.6f}' for v in probs) + '\n')
        f.write(f'{am}\n')
    print('[写出] tests/data/head_synth_feat.bin (46080 B) + head_synth_expect.txt')
    print('expect logits :', ' '.join(f'{v:.6f}' for v in logits))
    print('expect argmax :', am)


if __name__ == '__main__':
    main()
