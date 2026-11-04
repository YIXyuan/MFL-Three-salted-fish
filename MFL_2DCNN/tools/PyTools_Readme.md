# PyTools_Readme —— mfl2d_v2 全部 Python 脚本用途汇总

> 维护: 模型侧 | 更新: 2026-10-15
> 本目录是训练/量化/向量管线权威源。T2_kit_fixed\tools\（fpga_sim.py、gen_fpga_mem.py）
> 不在本子项目内，见文末交叉引用。

## 管线流程（按使用顺序）

```
check_env → preprocess_tar(G盘分卷→缓存) → train → evaluate → quantize_export
    → export_test_vectors(逐层向量) / export_structure(结构表) / gen_head_assets(ARM头资产)
    → compare_int8(量化阶梯评估)
board_probe(板端探针, 任意时刻只读) / tools\selfcheck_int8_chain(向量自检)
```

## 脚本清单

| 脚本 | 用途 | 关键用法 | 状态 |
|---|---|---|---|
| `config.py` | 全局配置（唯一需要修改的文件）：E/F 双盘路径布局、模型超参、量化/预处理常数 | 被所有脚本 import，不直接运行 | 活跃 |
| `check_env.py` | 环境自检：CUDA / torch / 依赖版本 / 数据就位 | `python check_env.py`（训练前先跑） | 活跃 |
| `preprocess.py` | 离线批量缩放 5000×2400→1024×480 存缓存（早期版本，全量训练已改用 tar 流式） | `python preprocess.py` | 备用 |
| `preprocess_tar.py` | 从 G 盘 tar 分卷**流式**预处理（不解压落地），生成 train/val/test 缓存 JPEG q95 | `python preprocess_tar.py --split-name train` | 活跃 |
| `train.py` | 训练入口：20 epoch、AdamW lr=2e-3、weighted CE (0.44/1.80/5.37)、label_smooth 0.05 | `python train.py [--epochs 30] [--resume]` | 活跃（已产出 best_model.pt epoch16） |
| `evaluate.py` | 测试集评估：acc / macro_f1 / severe_recall | `python evaluate.py [--max-test N]` | 活跃 |
| `model.py` | MFLCNN 模型定义；`conv_layers()`（conv+bn 枚举）；`fuse_bn_into_convs()`（BN 折叠，向量导出与量化共用）；`export_fp32_onnx()` | 被 train/quantize/export 向量 import | 活跃 |
| `dataset.py` | 图像扫描 / COCO+YOLO 双格式标签 / 图像级三分类 / 缓存读取 / DataLoader | 被 train 与向量导出共用 | 活跃 |
| `quantize_export.py` | INT8 PTQ 量化（Entropy 校准）+ 交付物导出：model_int8.onnx / quant_params.json / fpga_architecture_spec.json / quant_params_table.md | `python quantize_export.py [--model ...]`（非 ASCII 路径需在 ASCII 临时目录执行后拷回） | 活跃 |
| `compare_int8.py` | FP32 vs INT8 真实精度对比（量化阶梯 A/B/C/D 的 test-3000 argmax 一致率评估器） | `python compare_int8.py [--n 3000]` | 活跃 |
| `export_test_vectors.py` | 3 样本逐层向量（42 npy/样本 + manifest 含 layers_table 算子/scale 表 + README）。**10-15 修正版：必须 `fuse_bn_into_convs` 后抓取**（pre-BN 抓取已被 FPGA 成员审计否决） | `python export_test_vectors.py --from-existing`（数据盘离线回退）/ 不带参数 = 从 G 盘选样 | 活跃 |
| `export_structure.py` | 表格化模型结构文档 MODEL_STRUCTURE.md | `python export_structure.py` | 活跃 |
| `gen_head_assets.py` | 从 model_int8.onnx 提取 ARM 定点头资产（head_params.h/bin，最小 ONNX 解析器零依赖） | 产出已交付 T2_kit_fixed / MFL_app；重跑会覆盖，属云端联动件 | 活跃（谨慎） |
| `board_probe.py` | 板端探针：SSH 只读核查 PU 系统参数（uio/内核配置/内存/存储） | `python board_probe.py [--host 192.168.1.10]` | 活跃 |
| `gen_c_params旧.py` | 旧版 C 参数生成器 | — | **废弃**（被 T2_kit_fixed\tools\gen_fpga_mem.py 取代，仅留档） |
| `tools\selfcheck_int8_chain.py` | 向量自检：int8 链复算 conv00 vs `*_out_int8.npy`（\|Δ\|≤1 门槛，审计§附录.4 公式） | `python tools/selfcheck_int8_chain.py`（重导向量后必跑） | 活跃 |
| `tools\chain_check_dsh.py` | DSH 两条自检的全层版：①in==requant(relu/pool(out)) 逐层 ②in 反推 out 全 10 层 | `python tools/chain_check_dsh.py` | 活跃 |
| `output\probe_ort_env.py` | ORT 环境指纹探针（ISA 分派排查期一次性脚本） | — | 留档 |

## 已知坑（详见各脚本头注释与交接文档 §5）

1. 非 ASCII 路径：onnxruntime C++ 形状推断静默失败——量化/ORT 相关操作在 ASCII 临时目录执行后拷回。
2. torch 必须 cu128 源安装（CPU 轮子不可用）。
3. `load_model()` **不折叠 BN**——任何需要"与 int8 链层边界对齐"的张量抓取，必须先过
   `fuse_bn_into_convs()`（10-15 审计教训，已固化在 export_test_vectors.py）。

## 交叉引用（关联工具；fpga_sim / gen_fpga_mem 已收录本仓库 tools\，正本在 FPGA 车道）

| 工具 | 正本位置 | 用途 |
|---|---|---|
| fpga_sim.py | 本仓库 tools\（正本 T2_kit_fixed\tools\，10-17 修复版） | F=24 定点全链仿真器（round/floor 双模式），位级锚点 |
| gen_fpga_mem.py | 本仓库 tools\（正本 T2_kit_fixed\tools\） | 五件套 .mem 生成器（消费 quant_params.json + weights_int8） |
| gen_mfl_constants.py | Kosmo2_IP\tools\ | FPGA 侧常量/bank 打包（消费五件套） |
