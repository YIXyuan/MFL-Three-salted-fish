# -*- coding: utf-8 -*-
"""
数据集: 图像扫描 / COCO+YOLO 双格式标签解析 / 图像级三分类标签 / 缓存目录读取 / DataLoader
标签口径(与 config 一致): 图中无腐蚀框=normal; 腐蚀框最大面积占比 < 0.2%=light; >= 0.2%=severe
"""

import json
import random
from pathlib import Path

import numpy as np
from PIL import Image
from torch.utils.data import DataLoader, Dataset

import config as C

IMAGE_EXTS = [".png", ".jpg", ".jpeg", ".bmp"]
_RESIZE_FILTERS = {"bilinear": Image.BILINEAR, "nearest": Image.NEAREST,
                   "bicubic": Image.BICUBIC, "lanczos": Image.LANCZOS}

# YOLO class_id -> 类别名 (与数据集 classes.txt / COCO categories 顺序一致)
YOLO_CLASS_NAMES = ["MTL", "TEE", "BND", "CRC", "BRN", "GWA", "SWA",
                    "ESP", "VAL", "FLA", "CAS", "SLE"]


# ---------------------------------------------------------------------------
# 扫描与标签
# ---------------------------------------------------------------------------
def iter_image_files(image_dir):
    """目录下全部图像, 按文件名排序(保证可复现)"""
    image_dir = Path(image_dir)
    files = [p for p in image_dir.iterdir()
             if p.is_file() and p.suffix.lower() in IMAGE_EXTS]
    return sorted(files, key=lambda p: p.name)


def load_annotations_coco(json_path):
    """COCO json -> {文件主名stem: [(cat_name, x1, y1, x2, y2, ow, oh), ...]}, 坐标为原始像素空间.
    键用 stem(不带扩展名): 原始图为 .png 而缩放缓存为 .jpg, 按全名匹配会全部 miss."""
    with open(json_path, "r", encoding="utf-8") as f:
        coco = json.load(f)
    cat_names = {c["id"]: c["name"] for c in coco.get("categories", [])}
    sizes = {im["id"]: (im.get("width", C.ORIG_WIDTH), im.get("height", C.ORIG_HEIGHT))
             for im in coco.get("images", [])}
    names = {im["id"]: Path(im["file_name"]).stem for im in coco.get("images", [])}
    anns = {}
    for a in coco.get("annotations", []):
        x, y, w, h = a["bbox"]
        name = names.get(a["image_id"])
        if name is None:
            continue
        ow, oh = sizes.get(a["image_id"], (C.ORIG_WIDTH, C.ORIG_HEIGHT))
        anns.setdefault(name, []).append(
            (cat_names.get(a["category_id"], "?"), x, y, x + w, y + h, ow, oh))
    return anns


def load_annotations_yolo(label_dir, image_names):
    """YOLO txt 目录 -> {文件主名stem: [(cat_name, x1, y1, x2, y2, ow, oh), ...]} (反归一化到原图)"""
    label_dir = Path(label_dir)
    anns = {}
    for name in image_names:
        txt = label_dir / (Path(name).stem + ".txt")
        if not txt.exists():
            continue
        boxes = []
        for line in txt.read_text().splitlines():
            parts = line.split()
            if len(parts) != 5:
                continue
            cid, xc, yc, w, h = int(parts[0]), *map(float, parts[1:])
            boxes.append((YOLO_CLASS_NAMES[cid] if 0 <= cid < len(YOLO_CLASS_NAMES) else "?",
                          (xc - w / 2) * C.ORIG_WIDTH, (yc - h / 2) * C.ORIG_HEIGHT,
                          (xc + w / 2) * C.ORIG_WIDTH, (yc + h / 2) * C.ORIG_HEIGHT,
                          C.ORIG_WIDTH, C.ORIG_HEIGHT))
        if boxes:
            anns[Path(name).stem] = boxes
    return anns


def make_label(anns_for_image):
    """按 config 规则把检测框换算成图像级 3 分类标签"""
    if not anns_for_image:
        return 0
    ratios = [(x2 - x1) * (y2 - y1) / (ow * oh)
              for cat, x1, y1, x2, y2, ow, oh in anns_for_image
              if cat in C.CORROSION_CATEGORY_NAMES]
    if not ratios:
        return 0
    score = max(ratios) if C.AREA_RATIO_MODE == "max" else float(np.sum(ratios))
    return 2 if score >= C.SEVERE_AREA_RATIO else 1


def make_type_aux(anns_for_image):
    """腐蚀类型存在性 (MTL, CRC) -> [0/1, 0/1], 仅 ENABLE_TYPE_HEAD 时使用"""
    cats = {cat for cat, *_ in (anns_for_image or [])}
    return [1 if "MTL" in cats else 0, 1 if "CRC" in cats else 0]


def build_labels(image_names, label_json, label_dir, split):
    """返回与 image_names 对齐的标签; ENABLE_TYPE_HEAD 时同时返回 (N,2) 的类型存在性.
    文件名一律按 stem 匹配标注(与扩展名无关); 带缓存, 签名包含阈值/口径/开关,
    任何一项或代码版本变化都会自动失效重建."""
    cache_file = C.CACHE_DIR / f"labels_{split}.json"
    sig = "|".join(map(str, [
        "v3-stem", len(image_names), label_json,
        label_json.stat().st_mtime if label_json else 0, label_dir,
        C.SEVERE_AREA_RATIO, C.AREA_RATIO_MODE,
        ",".join(C.CORROSION_CATEGORY_NAMES), C.ENABLE_TYPE_HEAD]))
    if cache_file.exists():
        try:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
            if data.get("sig") == sig:
                labels = np.array(data["labels"], dtype=np.int64)
                if C.ENABLE_TYPE_HEAD:
                    return labels, np.array(data["aux"], dtype=np.float32)
                return labels
        except Exception:
            pass

    anns = {}
    if label_json and Path(label_json).exists():
        anns = load_annotations_coco(label_json)
    elif label_dir and Path(label_dir).exists():
        anns = load_annotations_yolo(label_dir, image_names)

    labels = [make_label(anns.get(Path(name).stem)) for name in image_names]
    payload = {"sig": sig, "labels": labels}
    if C.ENABLE_TYPE_HEAD:
        aux = [make_type_aux(anns.get(Path(name).stem)) for name in image_names]
        payload["aux"] = aux
    cache_file.write_text(json.dumps(payload), encoding="utf-8")
    if C.ENABLE_TYPE_HEAD:
        return np.array(labels, dtype=np.int64), np.array(payload["aux"], dtype=np.float32)
    return np.array(labels, dtype=np.int64)


# ---------------------------------------------------------------------------
# Dataset
# ---------------------------------------------------------------------------
def cache_path_for(split, image_path):
    ext = ".jpg" if C.CACHE_FORMAT == "jpeg" else ".png"
    return C.cache_split_dir(split) / (Path(image_path).stem + ext)


def load_image(image_path, split=None):
    """读图 -> 目标尺寸(BILINEAR) -> float32 /255 -> CHW. USE_CACHE=True 时优先读离线缩放缓存."""
    cache_p = cache_path_for(split, image_path) if (split and C.USE_CACHE) else None
    if cache_p is not None and cache_p.exists():
        img = Image.open(cache_p).convert("RGB")
    else:
        img = Image.open(image_path).convert("RGB")
    if img.size != (C.INPUT_WIDTH, C.INPUT_HEIGHT):
        img = img.resize((C.INPUT_WIDTH, C.INPUT_HEIGHT), _RESIZE_FILTERS[C.RESIZE_INTERPOLATION])
    arr = np.asarray(img, dtype=np.float32) / 255.0
    return np.ascontiguousarray(arr.transpose(2, 0, 1))


def augment(img):
    """训练增强: 水平翻转 + 亮度/对比度抖动 (仅训练集; 推理/FPGA 预处理不做任何增强)"""
    if random.random() < 0.5:
        img = img[:, :, ::-1]
    alpha = random.uniform(0.8, 1.2)   # 对比度
    beta = random.uniform(-0.1, 0.1)   # 亮度
    img = np.clip(img * alpha + beta, 0.0, 1.0)
    return np.ascontiguousarray(img)


class MFLDataset(Dataset):
    def __init__(self, image_paths, labels, split, training=False, aux=None):
        self.image_paths = [str(p) for p in image_paths]
        self.labels = np.asarray(labels, dtype=np.int64)
        self.aux = None if aux is None else np.asarray(aux, dtype=np.float32)
        self.split = split
        self.training = training

    def __len__(self):
        return len(self.image_paths)

    def __getitem__(self, idx):
        img = load_image(self.image_paths[idx], self.split)
        if self.training:
            img = augment(img)
        if self.aux is None:
            return img, int(self.labels[idx])
        return img, int(self.labels[idx]), self.aux[idx]


# ---------------------------------------------------------------------------
# 构建 DataLoader
# ---------------------------------------------------------------------------
def _stratified_indices(labels, val_ratio, seed):
    """分层抽取 val_ratio 比例作为验证集, 返回 (train_idx, val_idx)"""
    rng = np.random.RandomState(seed)
    train_idx, val_idx = [], []
    for cls in np.unique(labels):
        idx = np.where(labels == cls)[0]
        rng.shuffle(idx)
        n_val = int(round(len(idx) * val_ratio))
        val_idx.extend(idx[:n_val])
        train_idx.extend(idx[n_val:])
    return sorted(train_idx), sorted(val_idx)


def _scan_or_hint(image_dir, split):
    """扫描图像目录; 缺失/为空时报带指引的错误(提示先跑流式预处理)"""
    d = Path(image_dir) if image_dir else None
    if d is None or not d.exists():
        hint = ""
        vol = getattr(C, f"{split.upper()}_TAR_VOLUMES", None)
        if vol:
            hint = f"\n  缓存尚未生成: 先运行  python preprocess_tar.py --split-name {split}"
        raise RuntimeError(f"{split} 图像目录不存在: {image_dir}{hint}")
    files = iter_image_files(d)
    if not files:
        raise RuntimeError(f"{split} 图像目录为空: {d}"
                           + (f"\n  若预处理中断, 重跑 python preprocess_tar.py --split-name {split} 即可续传"
                              if vol_hint(split) else ""))
    return [str(p) for p in files]


def vol_hint(split):
    return bool(getattr(C, f"{split.upper()}_TAR_VOLUMES", None))


def _stratified_cap(paths, labels, cap, seed):
    """样本数上限截断(分层, 保证三类都在)"""
    rng = np.random.RandomState(seed)
    per_cls = {c: max(1, int(cap * np.mean(labels == c))) for c in np.unique(labels)}
    count = {c: 0 for c in per_cls}
    order = list(range(len(labels)))
    rng.shuffle(order)
    keep = []
    for i in order:
        c = labels[i]
        if count.get(c, 0) < per_cls.get(c, 0):
            keep.append(i)
            count[c] += 1
    keep = sorted(keep)
    return keep


def class_weights(train_labels):
    """逆频率类权重, 归一化到和为 NUM_CLASSES; 缺席类别权重为 1"""
    counts = np.array([max(1, np.sum(train_labels == c)) for c in range(C.NUM_CLASSES)])
    w = counts.sum() / (C.NUM_CLASSES * counts)
    return w.astype(np.float32)


def _loader(ds, batch_size, shuffle, seed):
    return DataLoader(ds, batch_size=batch_size, shuffle=shuffle,
                      num_workers=C.NUM_WORKERS, pin_memory=True,
                      persistent_workers=C.NUM_WORKERS > 0,
                      generator=torch_generator(seed) if shuffle else None)


def torch_generator(seed):
    g = __import__("torch").Generator()
    g.manual_seed(seed)
    return g


def build_data(batch_size=None, max_train=0, max_test=0):
    """返回 dict(train/val/test loader, class_w, meta). full 布局用官方 val; trial 自动切分."""
    meta = {}

    def get_labels(names, json_path, dir_path, split):
        out = build_labels(names, json_path, dir_path, split)
        return out if C.ENABLE_TYPE_HEAD else (out, None)

    # ---- 训练集 ----
    train_paths = _scan_or_hint(C.TRAIN_IMAGE_DIR, "train")
    train_labels, train_aux = get_labels([Path(p).name for p in train_paths],
                                         C.TRAIN_LABEL_JSON, C.TRAIN_LABEL_DIR, "train")
    if max_train > 0 and len(train_paths) > max_train:
        keep = _stratified_cap(train_paths, train_labels, max_train, C.SEED)
        train_paths = [train_paths[i] for i in keep]
        train_labels = train_labels[keep]
        train_aux = None if train_aux is None else train_aux[keep]

    # ---- 验证集 ----
    if C.VAL_IMAGE_DIR and Path(C.VAL_IMAGE_DIR).exists():
        val_paths = _scan_or_hint(C.VAL_IMAGE_DIR, "val")
        val_labels, val_aux = get_labels([Path(p).name for p in val_paths],
                                         C.VAL_LABEL_JSON, C.VAL_LABEL_DIR, "val")
    else:
        tr_idx, va_idx = _stratified_indices(train_labels, C.VAL_SPLIT, C.SEED)
        val_paths = [train_paths[i] for i in va_idx]
        val_labels = train_labels[va_idx]
        val_aux = None if train_aux is None else train_aux[va_idx]
        train_paths = [train_paths[i] for i in tr_idx]
        train_labels = train_labels[tr_idx]
        train_aux = None if train_aux is None else train_aux[tr_idx]
        meta["val_from"] = f"train 分层切分 {C.VAL_SPLIT:.0%}"

    # ---- 测试集 ----
    test_paths = (_scan_or_hint(C.TEST_IMAGE_DIR, "test")
                  if (C.TEST_IMAGE_DIR and Path(C.TEST_IMAGE_DIR).exists()) else [])
    if max_test > 0 and len(test_paths) > max_test:
        test_paths = test_paths[:max_test]
    has_test_label = (C.TEST_LABEL_JSON and Path(C.TEST_LABEL_JSON).exists()) or \
                     (C.TEST_LABEL_DIR and Path(C.TEST_LABEL_DIR).exists())
    if test_paths and has_test_label:
        test_labels, test_aux = get_labels([Path(p).name for p in test_paths],
                                           C.TEST_LABEL_JSON, C.TEST_LABEL_DIR, "test")
    else:
        test_labels = np.full(len(test_paths), -1, np.int64)
        test_aux = None
        if test_paths:
            print("[提示] test 无标签来源, 仅做推理不评估"
                  + (" (test 分卷被截断/未下载)" if DATA_LAYOUT_IS_FULL() else ""))

    meta.update(
        train_n=len(train_paths), val_n=len(val_paths), test_n=len(test_paths),
        train_counts=np.bincount(train_labels, minlength=C.NUM_CLASSES).tolist(),
        val_counts=np.bincount(val_labels, minlength=C.NUM_CLASSES).tolist(),
        test_labeled=bool(len(test_labels) > 0 and test_labels[0] >= 0),
        type_head=C.ENABLE_TYPE_HEAD,
    )
    if C.ENABLE_TYPE_HEAD and train_aux is not None:
        meta["train_type_counts"] = {"MTL": int(train_aux[:, 0].sum()),
                                     "CRC": int(train_aux[:, 1].sum())}

    w = class_weights(train_labels)
    seed = C.SEED
    return {
        "train": _loader(MFLDataset(train_paths, train_labels, "train", True, train_aux),
                         batch_size or C.BATCH_SIZE, True, seed),
        "val": _loader(MFLDataset(val_paths, val_labels, "train", False, val_aux),
                       batch_size or C.BATCH_SIZE, False, seed),
        "test": _loader(MFLDataset(test_paths, test_labels, "test", False, test_aux),
                        batch_size or C.BATCH_SIZE, False, seed),
        "class_w": w,
        "meta": meta,
    }


def DATA_LAYOUT_IS_FULL():
    return C.DATA_LAYOUT == "full"
