# -*- coding: utf-8 -*-
"""环境自检: CUDA / 依赖版本 / 数据就位情况. 训练前先跑一遍: python check_env.py"""

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path


def _mod(name):
    spec = importlib.util.find_spec(name)
    return (name, importlib.import_module(name).__version__) if spec else (name, "未安装")


def main():
    print("=" * 62)
    print("Python:", sys.version.split()[0], "@", sys.executable)

    # --- NVIDIA 驱动 ---
    if shutil.which("nvidia-smi"):
        try:
            out = subprocess.run(["nvidia-smi"], capture_output=True, text=True, timeout=15).stdout
            for line in out.splitlines():
                if "Driver" in line or "GPU" in line or line.strip().startswith("0"):
                    print("  ", line.strip())
        except Exception as e:
            print("nvidia-smi 执行失败:", e)
    else:
        print("nvidia-smi 不存在: 未装驱动或非 NVIDIA 显卡")

    # --- torch / CUDA ---
    torch_ok = False
    try:
        import torch
        print("-" * 62)
        print("torch:", torch.__version__)
        print("torch cuda build:", torch.version.cuda)
        print("cuda available:", torch.cuda.is_available())
        if torch.cuda.is_available():
            torch_ok = True
            print("GPU:", torch.cuda.get_device_name(0),
                  "| 显存: %.1f GB" % (torch.cuda.get_device_properties(0).total_memory / 2**30))
            print("cudnn:", torch.backends.cudnn.version(),
                  "| bf16 支持:", torch.cuda.is_bf16_supported())
        else:
            print("cudnn: n/a")
            print("-" * 62)
            if torch.version.cuda is None:
                print("[诊断] 当前 torch 是 CPU-only 轮子(版本号带 +cpu). 修复:")
                print("  python -m pip uninstall -y torch")
                print("  python -m pip install torch --index-url https://download.pytorch.org/whl/cu128")
            else:
                print("[诊断] torch 带 CUDA 但不可用: 多为驱动过旧(看上面驱动版本), 或多环境装错解释器.")
    except ImportError:
        print("torch 未安装: python -m pip install torch --index-url https://download.pytorch.org/whl/cu128")

    # --- 其余依赖 ---
    print("-" * 62)
    for name in ("numpy", "PIL", "pandas", "openpyxl", "matplotlib", "onnx", "onnxruntime", "tqdm"):
        n, v = _mod(name)
        print(f"{n:>14}: {v}")

    # --- 数据就位 ---
    print("-" * 62)
    try:
        import config as C
        rows = []

        def add(label, path, ok, hint=""):
            rows.append((("OK " if ok else "缺 ") + label, str(path), hint))

        add("训练图缓存", C.TRAIN_IMAGE_DIR, C.TRAIN_IMAGE_DIR.exists(),
            "" if C.TRAIN_IMAGE_DIR.exists() else "先运行: python preprocess_tar.py --split-name train")
        add("训练标签(COCO)", C.TRAIN_LABEL_JSON,
            C.TRAIN_LABEL_JSON is not None and C.TRAIN_LABEL_JSON.exists())
        add("训练标签(YOLO)", C.TRAIN_LABEL_DIR,
            C.TRAIN_LABEL_DIR is not None and C.TRAIN_LABEL_DIR.exists())
        val_ok = C.VAL_IMAGE_DIR is not None and Path(C.VAL_IMAGE_DIR).exists()
        add("验证图缓存", C.VAL_IMAGE_DIR, val_ok,
            "" if val_ok else "先运行: python preprocess_tar.py --split-name val"
            if C.VAL_IMAGE_DIR else "未配置(将从训练集分层切分)")
        add("验证标签(COCO)", C.VAL_LABEL_JSON,
            C.VAL_LABEL_JSON is not None and C.VAL_LABEL_JSON.exists())
        if C.TEST_IMAGE_DIR:
            add("测试图缓存", C.TEST_IMAGE_DIR, C.TEST_IMAGE_DIR.exists())
        else:
            rows.append(("缺 测试集", "未配置", "本轮评估主力为官方 val, 不影响训练"))
        if getattr(C, "TRAIN_TAR_VOLUMES", None):
            from glob import glob
            vols = sorted(glob(C.TRAIN_TAR_VOLUMES))
            n = len(vols)
            size = sum(Path(p).stat().st_size for p in vols) / 2**30 if vols else 0
            rows.append((f"OK 训练tar分卷 x{n}" if vols else "缺 训练tar分卷",
                         C.TRAIN_TAR_VOLUMES, f"{size:.0f} GiB" if vols else "检查 G 盘挂载"))
        for label, path, hint in rows:
            print(f"[{label:>14}] {path}  {hint}")
        print(f"模型配比: {C.MODEL_PROFILE} | 输入: {C.INPUT_HEIGHT}x{C.INPUT_WIDTH} | "
              f"severe阈值: {C.SEVERE_AREA_RATIO} | 类型双头: {'开' if C.ENABLE_TYPE_HEAD else '关'}")
        cached = len(list(Path(C.TRAIN_IMAGE_DIR).glob("*.jpg"))) \
            if C.TRAIN_IMAGE_DIR and C.TRAIN_IMAGE_DIR.exists() else 0
        if 0 < cached < 100000:
            print(f"[提示] 训练缓存当前 {cached} 张(全量应约 144,192), 可随时续跑 preprocess_tar.py")
    except Exception as e:
        print("读取 config 失败:", e)

    print("=" * 62)
    print("结论:", "GPU 就绪, 可以训练" if torch_ok else "GPU 不可用, 请按上方[诊断]修复后再训练")


if __name__ == "__main__":
    main()
