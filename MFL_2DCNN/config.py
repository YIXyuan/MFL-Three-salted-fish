# -*- coding: utf-8 -*-
"""
MFL 2D-CNN 管道腐蚀识别 —— 全局配置

DATA_LAYOUT 两种布局:
  "full"  全量训练(默认): 训练只读缓存,需先用 preprocess_tar.py 流式预处理(原始分卷保持不动)。
  "trial" 本地小样本试训练, 用于回归验证。
"""

from pathlib import Path

# ---------------------------------------------------------------------------
# 目录
# ---------------------------------------------------------------------------
THIS_DIR = Path(__file__).resolve().parent          # 代码所在目录
WORKSPACE = THIS_DIR.parent
PRJ_ROOT = WORKSPACE.parent

OUTPUT_DIR = THIS_DIR / "output"
MODEL_DIR = OUTPUT_DIR / "models"
LOG_DIR = OUTPUT_DIR / "logs"
QUANT_EXPORT_DIR = OUTPUT_DIR / "quant_export"
TEST_VECTOR_DIR = OUTPUT_DIR / "test_vectors"
EVAL_RESULT_DIR = OUTPUT_DIR / "eval_results"

# ---------------------------------------------------------------------------
# 数据布局
# ---------------------------------------------------------------------------
DATA_LAYOUT = "full"

# 缓存子目录命名(与训练 split 的映射)
CACHE_SPLIT_NAMES = {"train": "train-cache", "val": "val-cache", "test": "test-cache"}

if DATA_LAYOUT == "full":
    F_ROOT = Path(r"")      # 数据文件所在的工作副本
    G_DATA = Path(r"")      # 数据集分卷与缓存所在数据盘

    # tar 分卷(glob 串, 无 .tar 后缀的按字节切分 tar, 须按序拼接读取)
    TRAIN_TAR_VOLUMES = str(G_DATA / "train" / "train_part_*")   # 11 卷约 328 GiB
    VAL_TAR_VOLUMES = str(G_DATA / "val" / "val_part_*")         # 4 卷约 109.5 GiB
    TEST_TAR_VOLUMES = str(G_DATA / "test" / "test_part_*")      # 4 卷约 109 GiB

    # 标签(COCO 为主, YOLO txt 为备用; 两者内容一致, id 差 1 已在代码内对齐)
    TRAIN_LABEL_JSON = F_ROOT / "MFL_datafile" / "train_coco.json"   # 144,192 图
    VAL_LABEL_JSON = F_ROOT / "MFL_datafile" / "val_coco.json"       # 48,064 图
    TEST_LABEL_JSON = F_ROOT / "MFL_datafile" / "test_coco.json"     # 48,064 图
    TRAIN_LABEL_DIR = F_ROOT / "labels" / "train_labels"
    VAL_LABEL_DIR = F_ROOT / "labels" / "val_labels"
    TEST_LABEL_DIR = None   # F_ROOT / "labels" / "test_labels"      # test 标签统一走 COCO

    # 图像目录 = 流式预处理产物(先跑 preprocess_tar.py, 训练/评估/量化只读这里)
    CACHE_ROOT = G_DATA / "cache"                   # JPEG q95 实测约 291KB/张, train+val+test 约 69GB
    TRAIN_IMAGE_DIR = CACHE_ROOT / CACHE_SPLIT_NAMES["train"]
    VAL_IMAGE_DIR = CACHE_ROOT / CACHE_SPLIT_NAMES["val"]
    TEST_IMAGE_DIR = CACHE_ROOT / CACHE_SPLIT_NAMES["test"]
else:  # trial
    TRAIN_TAR_VOLUMES = None
    VAL_TAR_VOLUMES = None
    TEST_TAR_VOLUMES = None
    TRAIN_IMAGE_DIR = PRJ_ROOT / "Test_Version" / "train_picture"
    TRAIN_LABEL_JSON = WORKSPACE / "MFL_data" / "train_coco.json"
    TRAIN_LABEL_DIR = None
    VAL_IMAGE_DIR = None                            # None -> 自动从训练集分层切 VAL_SPLIT
    VAL_LABEL_JSON = None
    VAL_LABEL_DIR = None
    TEST_IMAGE_DIR = PRJ_ROOT / "Test_Version" / "test_picture" / "images"
    TEST_LABEL_JSON = None
    TEST_LABEL_DIR = None
    CACHE_ROOT = OUTPUT_DIR / "cache"

CACHE_DIR = CACHE_ROOT          # 兼容旧名
USE_CACHE = True                # 训练优先读缩放缓存(缓存文件不存在则回退读原图)
CACHE_FORMAT = "jpeg"
CACHE_JPEG_QUALITY = 95         # 实测约 291KB/张 -> train+val 全量约 55GB

# ---------------------------------------------------------------------------
# 图像 / 预处理 (FPGA 端必须严格复现: BILINEAR 缩放 + /255 归一化)
# ---------------------------------------------------------------------------
ORIG_WIDTH, ORIG_HEIGHT = 5000, 2400                # 原始 MFL 伪彩图
INPUT_WIDTH, INPUT_HEIGHT = 1024, 480               # 模型输入 (5 次池化整除: 1024/32=32, 480/32=15)
RESIZE_INTERPOLATION = "bilinear"
NORMALIZE_MODE = "scale"                            # 仅 /255, 不做均值方差 (FPGA 定点友好)

# ---------------------------------------------------------------------------
# 标签规则 (图像级三分类, 由 MTL 检测框换算)
# ---------------------------------------------------------------------------
CLASS_NAMES = ["normal", "light_corrosion", "severe_corrosion"]
NUM_CLASSES = 3
CORROSION_CATEGORY_NAMES = ["MTL"]                  # 参与严重度判定的类别
SEVERE_AREA_RATIO = 0.001        # 最大腐蚀框面积占比 >= 该值 -> severe (全量下 severe=8,956 张)
AREA_RATIO_MODE = "max"          # "max": 单框最大占比; "sum": 所有腐蚀框占比求和

# 可选腐蚀类型双头(默认关): 启用后 ARM 分类头额外输出 MTL/CRC 存在性(BCE), FPGA 侧不变
ENABLE_TYPE_HEAD = False
TYPE_LOSS_LAMBDA = 0.5                              # 类型 BCE 在总损失中的权重

# ---------------------------------------------------------------------------
# 模型 (FPGA 友好 VGG 风格: 3x3 conv s1 p1 + BN + ReLU, 每块末尾 MaxPool2)
# features -> FPGA(PA, 权重 INT8 片上驻留); GAP + FC -> ARM(PU)
# PG2K100 片上 BRAM = 144x36Kb = 5.06Mb = 632KB, 权重预算 <= ~400KB(INT8)
# ---------------------------------------------------------------------------
MODEL_PROFILE = [16, 32, 64, 96, 96]    # 每 block 输出通道数; 权重约 367KB 片上驻留
# 候选: [16,32,48,96,96]=333KB | [16,32,64,96,96]=367KB(默认) | [16,32,64,128,128]=574KB(需复核)
#       [32,64,128,256,512]=4.4MB 豆包初版, 片上放不下需 DDR3 权重流送
CONVS_PER_BLOCK = 2
FC_HIDDEN = 256

# ---------------------------------------------------------------------------
# 训练超参 (RTX 4060 Laptop 8G, 全量 144K 张/纯缓存)
# ---------------------------------------------------------------------------
BATCH_SIZE = 32                  # 显存不足(OOM)时退 16
NUM_EPOCHS = 20                  # 全量数据 20 轮足够, best 按分数自动留
LEARNING_RATE = 2e-3             # 随 batch 从 16->32 线性放大
WEIGHT_DECAY = 1e-4
WARMUP_EPOCHS = 2
MIN_LR_RATIO = 0.01
LABEL_SMOOTHING = 0.05
VAL_SPLIT = 0.15                 # 仅 trial(无独立 val)时生效
SEED = 42
NUM_WORKERS = 8                  # 读缓存 JPEG 很快, 8 进程足够喂满 GPU
AMP_DTYPE = "auto"               # auto: 4060 支持 bf16; 可强制 "bf16"/"fp16"/"off"
CHANNELS_LAST = True
GRAD_CLIP_NORM = 5.0
BEST_SCORE_SEVERE_RECALL_W = 0.7
BEST_SCORE_ACC_W = 0.3
MAX_TRAIN_SAMPLES = 0            # >0 冒烟/调试截断
MAX_TEST_SAMPLES = 0

# ---------------------------------------------------------------------------
# INT8 量化 (PTQ 静态量化, QDQ 格式; 权重 per-channel, 激活 per-tensor)
# 2026-09-29 T1 定稿: ① 高置信翻转主因是 ARM 侧旧版 ORT 环境(见工作区根
# 《量化分歧根因发现-ORT执行环境.md》); ② 校准阶梯实测(test-3000 argmax 一致率):
# MinMax+512 基线 95.1% -> A Percentile+1024 95.5% -> B Entropy+1024 97.5%
# -> C Entropy+1024+混池 96.4% -> D Entropy+2048 97.8%(当前配置, 最优).
# 剩余 ~2% 分歧为 10 层逐级 requant 的固有噪声; INT8 acc 不低于 FP32(+0.1pt),
# severe_recall -1.6pp, 高置信翻转 12/26 -> 9/3000. 98% 硬线是否放宽由团队
# 按根因结论决策(禁改模型结构, QAT 另立课题).
# ---------------------------------------------------------------------------
CALIB_SAMPLES = 2048              # 校准样本数(阶梯 D=2048; A=1024+Percentile 95.5%, B=1024+Entropy 97.5%, C=混池 96.4%)
CALIB_METHOD = "Entropy"          # MinMax | Entropy | Percentile (阶梯 B/D: Entropy 最优)
CALIB_PERCENTILE = 99.999         # 仅 Percentile 方法生效 (extra_options "CalibPercentile")
CALIB_POOL = "train"              # 校准图池: "train"(B/D 最优) | "train+val"(阶梯 C, 已测更差)
ONNX_OPSET = 17
QUANT_OP_TYPES = ["Conv", "Gemm", "MatMul"]   # gen_head_assets.py 依赖 Gemm 已量化, 勿移除
ACTIVATION_SYMMETRIC = True
N_VERIFY_DEFAULT = 300            # quantize_export --n-verify 默认值(独立验证样本数)

for _d in (OUTPUT_DIR, MODEL_DIR, LOG_DIR, QUANT_EXPORT_DIR, TEST_VECTOR_DIR, EVAL_RESULT_DIR):
    _d.mkdir(parents=True, exist_ok=True)


def cache_split_dir(split: str) -> Path:
    """split -> 缓存子目录 (train -> <CACHE_ROOT>/train-cache)"""
    return Path(CACHE_ROOT) / CACHE_SPLIT_NAMES[split]


def model_name() -> str:
    """当前配置对应的模型名, 用于产物命名, 例如 mfl2d_p16_32_64_96_96"""
    return "mfl2d_p" + "_".join(str(c) for c in MODEL_PROFILE)


def get_device(allow_cpu: bool = False):
    """返回 torch.device. 训练必须用 GPU: 检测失败时给出诊断而不是静默回退 CPU."""
    import torch
    if torch.cuda.is_available():
        return torch.device("cuda")
    msg = (
        "[错误] torch.cuda.is_available() == False, 无法使用 GPU.\n"
        f"  torch 版本: {torch.__version__} (cuda build: {torch.version.cuda})\n"
        "  常见原因与修复:\n"
        "    1) 装了 CPU-only 轮子(版本号带 +cpu): 执行\n"
        "       python -m pip uninstall -y torch\n"
        "       python -m pip install torch --index-url https://download.pytorch.org/whl/cu128\n"
        "    2) 显卡驱动过旧: nvidia-smi 看驱动版本, 到 NVIDIA 官网更新\n"
        "    3) 多个 Python 环境: 确认 python 指向装了 CUDA 版 torch 的那个\n"
        "  运行 python check_env.py 可查看完整诊断."
    )
    if allow_cpu:
        print("[警告] 未检测到 CUDA, 按要求以 CPU 模式继续(速度极慢, 仅调试用)")
        return torch.device("cpu")
    raise RuntimeError(msg)
