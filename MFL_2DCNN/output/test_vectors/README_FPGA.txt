FPGA 逐层测试向量说明 (v2, BN 折叠图抓取 — 2026-10-15 审计修正版)
====================
模型: ...\mfl2d_v2\output\models\best_model.pt  配比: [16, 32, 64, 96, 96]
图语义: BN 已折叠进 conv 权重(fuse_bn_into_convs), 与 ORT 融合图/int8 链同构。
  *_out = 第 XX 层 conv 的输出(pre-ReLU/pre-Pool) = int8 链该层 requant 前的 f32 域;
  *_in  = 第 XX 层 conv 的输入 = relu((pool) 前层 out) —— f32 级精确成立,
          同 scale 边界(int8)为逐元素直通, 异 scale 边界满足 Mc=s_out/s_in 比例关系;
  末层: conv09_out 之后接 ReLU+MaxPool 得最终 feat(96x15x32, 全非负)。
每层算子序列(relu_after/pool_after/边界比例)见 manifest.json 的 layers_table,
层配置生成器可直接照抄。
每个 sample_* 目录:
  input_f32.npy / input_int8.npy     网络输入 (1,3,480,1024), int8 按 input_scale 量化
  convXX_in_f32.npy / convXX_in_int8.npy   第 XX 层卷积输入 (f32 存为 float16)
  convXX_out_f32.npy / convXX_out_int8.npy 第 XX 层卷积输出
int8 量化规则: int8 = clip(round(f32 / scale), -128, 127), scale 见 manifest.json
  (f32 与 int8 文件自洽受 float16 存储噪声影响, 一致率 ~99.9%, 残余 ±1 属正常)
NPY 格式: numpy 标准 \x93NUMPY 魔数(np.save 默认), np.load 直接可读。
比对标准: FPGA 每层 int8 输出与 *_out_int8.npy 逐元素 |diff| <= 1 为合格;
最终 logits 与 manifest 中 logits_f32 反量化后误差 < 0.1 为合格.

tips: 向量为 FP32 图参考(FP32 前向 + 按 ORT scale 量化), 与纯 int8 链逐位对比会带
输入量化与累加域的 ±1~2 固有差; 位级(零差)对拍请用 fpga_sim.py 定点链。
