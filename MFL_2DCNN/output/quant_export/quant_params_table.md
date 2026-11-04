# INT8 量化参数表 (自动生成, 与 quant_params.json / weights_int8/ 严格一致)

- 模型: `mfl2d_p16_32_64_96_96`  输入: `1x3x480x1024`
- 输入量化: scale=7.874016e-03, zp=0 (对称 int8)
- 片上 RAM 预算(推荐逐层串行/块内流水): 权重 367.2KB + 偏置 2.4KB + 块内行缓冲 72.0KB + 余量 20KB = **461.5KB / 632KB** （全网络流水中行缓冲升至 297.0KB, 合计 686.5KB, ✗ 需 2 行方案或分布式 RAM 分担）

## FPGA 侧: 卷积层 (顺序执行, 逐层 requant)

| 层 | 通道 in→out | 输出 H×W | act_in scale | weight scale (per-ch) | act_out scale | 偏置 |
|---|---|---|---|---|---|---|
| conv00 | 3→16 | 480×1024 | 7.874e-03 | 2.807e-03~6.968e-02 (per-channel x16) | 2.218e-01 | int32 |
| conv01 | 16→16 | 480×1024 | 1.463e-01 | 1.999e-04~3.978e-03 (per-channel x16) | 1.546e-01 | int32 |
| conv02 | 16→32 | 240×512 | 9.970e-02 | 1.092e-04~3.479e-03 (per-channel x32) | 1.349e-01 | int32 |
| conv03 | 32→32 | 240×512 | 1.349e-01 | 2.548e-04~2.588e-03 (per-channel x32) | 2.001e-01 | int32 |
| conv04 | 32→64 | 120×256 | 2.001e-01 | 3.727e-07~3.575e-03 (per-channel x64) | 2.608e-01 | int32 |
| conv05 | 64→64 | 120×256 | 1.449e-01 | 2.326e-04~1.985e-03 (per-channel x64) | 2.058e-01 | int32 |
| conv06 | 64→96 | 60×128 | 2.058e-01 | 1.608e-05~1.232e-03 (per-channel x96) | 2.804e-01 | int32 |
| conv07 | 96→96 | 60×128 | 2.804e-01 | 3.599e-07~1.344e-03 (per-channel x96) | 2.973e-01 | int32 |
| conv08 | 96→96 | 30×64 | 2.536e-01 | 5.256e-05~1.056e-03 (per-channel x96) | 1.644e-01 | int32 |
| conv09 | 96→96 | 30×64 | 1.226e-01 | 2.161e-05~1.360e-03 (per-channel x96) | 1.373e-01 | int32 |

## ARM 侧: 分类头 (GAP 之后)

| 层 | 权重形状 | act_in scale | weight scale | act_out scale |
|---|---|---|---|---|
| fc1 | 256x96 | 6.698e-03 | 7.932e-04~1.818e-02 (per-channel x256) | 4.089e-02 |
| fc2 | 3x256 | 1.453e-02 | 5.256e-03~7.698e-03 (per-channel x3) | 2.870e-02 |

## 定点数据流 (每层卷积)

```
acc32 = Σ(x_i8 · w_i8) + b_i32            # INT32 累加
y_f   = acc32 × act_in_scale × w_scale[c]  # 反量化到 float (c=输出通道)
y_i8  = clamp(round(y_f / act_out_scale), -128, 127)   # 再量化, 喂下一层
```

> 比对验收: 与 test_vectors/ 中逐层 `*_out_int8.npy` 差值 |Δ|≤1 为合格。
