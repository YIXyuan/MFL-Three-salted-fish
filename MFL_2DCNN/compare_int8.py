# -*- coding: utf-8 -*-
"""
FP32 vs INT8 真实精度对比: python compare_int8.py [--split auto] [--n 3000]

对 quantize_export.py 的两个产物(model_fp32_fused.onnx / model_int8.onnx)做同运行时、
同样本、同序的逐张推理对比, 给出量化真实掉点——交付 FPGA/ARM 组前的验收依据。

数据源选择(--split):
  auto(默认): test 可用则用 test(自动探测 cache\\test-cache 与 test_coco.json 常见位置),
              否则回退官方 val; val 也没有时报错并给指引
  val / test: 强制指定
  --images-dir + [--label-json]: 手动指定任意图像目录; 有标注出精度指标,
              无标注则进"纯一致率模式"(只测 FP32/INT8 argmax 一致率与翻转审计,
              供 renamed 等场景数据集的全量判决)

翻转审计(2026-09-29 T1 新增, 口径与复测交付 spotcheck_int8.py 对齐):
  统计 FP32->INT8 的 argmax 翻转, 含 fp32_margin(top1-top2 概率差)、
  hi_conf_flips(margin>=0.15)、翻转方向矩阵(fp32类 x int8类)、int8 侧 p_max 分布。

其他参数: --n 3000 抽样张数(0=全量); --seed 可复现; --fp32/--int8 覆盖默认 onnx 路径。
产物: 控制台对比表 + eval_results/int8_vs_fp32_report.json
"""

import argparse
import json
import time
from pathlib import Path

import numpy as np
from tqdm import tqdm

import config as C
from dataset import build_labels, load_image

INPUT_NAME = "input"
HI_CONF_MARGIN = 0.15      # 与 spotcheck_int8.py 一致: fp32 top1-top2 概率差 >= 0.15 视为高置信


# ---------------------------------------------------------------------------
# 数据源
# ---------------------------------------------------------------------------
def probe_test_assets():
    """探测 test 的缓存图像目录与标注 json, 返回 (image_dir, label_json) 或 (None, None)"""
    img_dir = C.cache_split_dir("test")
    if not (img_dir.exists() and any(img_dir.glob("*.jpg"))):
        return None, None
    candidates = []
    if C.TEST_LABEL_JSON:
        candidates.append(Path(C.TEST_LABEL_JSON))
    f_root = getattr(C, "F_ROOT", None)
    g_data = getattr(C, "G_DATA", None)
    if f_root:
        candidates += [f_root / "MFL_datafile" / "test_coco.json",
                       f_root / "MFL_datafile" / "Test_coco.json"]
    if g_data:
        candidates += [g_data / "test_coco.json", g_data / "test" / "test_coco.json"]
    candidates.append(C.WORKSPACE / "MFL_data" / "test_coco.json")
    for p in candidates:
        if p and Path(p).exists():
            return img_dir, Path(p)
    return None, None


def resolve_split(args):
    """返回 (split名, image_paths, label_json或None)"""
    if args.images_dir:
        d = Path(args.images_dir)
        if not d.exists():
            raise SystemExit(f"图像目录不存在: {d}")
        files = sorted(p for p in d.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
        if args.glob:
            import fnmatch
            files = [p for p in files if fnmatch.fnmatch(p.name, args.glob)]
            print(f"[数据] glob 过滤 '{args.glob}' -> {len(files)} 张")
        if not files:
            raise SystemExit(f"图像目录为空(或 glob 无匹配): {d}")
        if args.label_json:
            return "custom", [str(p) for p in files], Path(args.label_json)
        print("[数据] 未提供 --label-json: 纯一致率模式(无精度指标, 仅一致率+翻转审计)")
        return "custom", [str(p) for p in files], None

    if args.split in ("auto", "test"):
        img_dir, label_json = probe_test_assets()
        if img_dir:
            files = sorted(p for p in img_dir.iterdir() if p.suffix.lower() == ".jpg")
            print(f"[数据] test 就绪: {img_dir} ({len(files)} 张), 标注 {label_json}")
            return "test", [str(p) for p in files], label_json
        if args.split == "test":
            raise SystemExit("test 尚不可用: 需要 cache\\test-cache 图像(先跑 "
                             "preprocess_tar.py --split-name test)和 test_coco.json")
        print("[数据] test 未就绪(分卷未下载完或未预处理), 回退官方 val")

    img_dir = C.cache_split_dir("val")
    if not img_dir.exists():
        raise SystemExit(f"val 缓存不存在: {img_dir} (先跑 preprocess_tar.py --split-name val)")
    if not (C.VAL_LABEL_JSON and Path(C.VAL_LABEL_JSON).exists()):
        raise SystemExit(f"val 标注不存在: {C.VAL_LABEL_JSON}")
    files = sorted(p for p in img_dir.iterdir() if p.suffix.lower() == ".jpg")
    print(f"[数据] val: {img_dir} ({len(files)} 张), 标注 {C.VAL_LABEL_JSON}")
    return "val", [str(p) for p in files], Path(C.VAL_LABEL_JSON)


def stratified_sample(paths, labels, n, seed):
    """按类别比例分层抽样, 返回抽中的索引(顺序保持原序, 保证两个模型吃同样的样本)"""
    if n <= 0 or n >= len(paths):
        return np.arange(len(paths))
    rng = np.random.RandomState(seed)
    counts = np.bincount(labels, minlength=C.NUM_CLASSES)
    quota = np.floor(n * counts / max(1, len(paths))).astype(int)
    # 余数补给最大的类, 保证总数恰为 n
    while quota.sum() < n:
        quota[int(np.argmax(counts - quota * len(paths) / max(1, n)))] += 1
    pick = []
    for c in range(C.NUM_CLASSES):
        idx = np.where(labels == c)[0]
        rng.shuffle(idx)
        pick.extend(idx[:quota[c]])
    pick = sorted(pick)
    print(f"[抽样] {len(pick)}/{len(paths)} 张, 各类 {np.bincount(labels[pick], minlength=C.NUM_CLASSES).tolist()}")
    return np.array(pick)


def linear_sample(paths, n):
    """无标注时均匀抽样(保持原序)"""
    if n <= 0 or n >= len(paths):
        return np.arange(len(paths))
    return np.linspace(0, len(paths) - 1, n).round().astype(int)


# ---------------------------------------------------------------------------
# 对比
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="FP32 vs INT8 量化精度对比")
    ap.add_argument("--split", default="auto", choices=["auto", "val", "test"])
    ap.add_argument("--n", type=int, default=3000, help="抽样张数, 0=全量")
    ap.add_argument("--seed", type=int, default=C.SEED)
    ap.add_argument("--fp32", default=str(C.QUANT_EXPORT_DIR / "model_fp32_fused.onnx"))
    ap.add_argument("--int8", default=str(C.QUANT_EXPORT_DIR / "model_int8.onnx"))
    ap.add_argument("--images-dir", default=None)
    ap.add_argument("--glob", default=None,
                    help="图像名过滤(如 \"P000[12]_*.jpg\"), 与 --images-dir 配合, 可按点位/桶分别判决")
    ap.add_argument("--label-json", default=None,
                    help="COCO 标注(可选): 有则出精度指标, 无则纯一致率模式")
    args = ap.parse_args()

    import onnxruntime as ort

    for p in (args.fp32, args.int8):
        if not Path(p).exists():
            raise SystemExit(f"缺少文件: {p} (先跑 quantize_export.py)")

    split, paths, label_json = resolve_split(args)
    labels = None
    if label_json is not None:
        lbl = build_labels([Path(p).stem for p in paths], label_json, None,
                           "test" if split in ("test", "custom") else "val")
        labels = lbl[0] if isinstance(lbl, tuple) else lbl
        labeled = labels >= 0
        paths = [p for p, ok in zip(paths, labeled) if ok]
        labels = labels[labeled]
        if len(paths) == 0:
            raise SystemExit("标注里没有任何一张与图像对得上, 请检查标注文件")
        pick = stratified_sample(paths, labels, args.n, args.seed)
    else:
        pick = linear_sample(paths, args.n)
        print(f"[抽样] {len(pick)}/{len(paths)} 张 (无标注, 均匀抽样)")

    so32 = ort.InferenceSession(args.fp32, providers=["CPUExecutionProvider"])
    so8 = ort.InferenceSession(args.int8, providers=["CPUExecutionProvider"])

    n_cls = C.NUM_CLASSES
    labeled_mode = labels is not None
    cm32 = np.zeros((n_cls, n_cls), np.int64) if labeled_mode else None
    cm8 = np.zeros((n_cls, n_cls), np.int64) if labeled_mode else None
    flip_matrix = np.zeros((n_cls, n_cls), np.int64)        # [fp32类, int8类]
    agree = 0
    flip_margins, flip_int8_pmax = [], []
    flip_records = []                                        # 留档用, 上限 200 条
    diff_sum = diff_max = 0.0
    t0 = time.time()
    for k, i in enumerate(tqdm(pick, ncols=70, unit="img")):
        load_split = {"val": "val", "test": "test"}.get(split)   # custom 目录不查缓存
        x = load_image(paths[i], load_split)[np.newaxis]
        r32 = severity_logits(so32.run(None, {INPUT_NAME: x}))
        r8 = severity_logits(so8.run(None, {INPUT_NAME: x}))
        p32v, p8v = softmax1d(r32), softmax1d(r8)
        p32, p8 = int(r32.argmax()), int(r8.argmax())
        if labeled_mode:
            y = int(labels[i])
            cm32[y, p32] += 1
            cm8[y, p8] += 1
        agree += int(p32 == p8)
        if p32 != p8:
            srt = np.sort(p32v)
            margin = float(srt[-1] - srt[-2])
            flip_matrix[p32, p8] += 1
            flip_margins.append(margin)
            flip_int8_pmax.append(float(p8v.max()))
            if len(flip_records) < 200:
                flip_records.append({
                    "image": Path(paths[i]).name, "fp32_pred": C.CLASS_NAMES[p32],
                    "int8_pred": C.CLASS_NAMES[p8],
                    "fp32_p": [round(float(v), 4) for v in p32v],
                    "int8_p": [round(float(v), 4) for v in p8v],
                    "fp32_margin": round(margin, 4),
                    "hi_conf": bool(margin >= HI_CONF_MARGIN)})
        d = float(np.abs(r32 - r8).max())
        diff_max = max(diff_max, d)
        diff_sum += d
        if (k + 1) % 500 == 0:
            msg = f"  进度 {k+1}: agree={agree/(k+1):.4f} flips={len(flip_margins)}"
            if labeled_mode:
                msg += f" acc32={np.trace(cm32)/cm32.sum():.4f} acc8={np.trace(cm8)/cm8.sum():.4f}"
            tqdm.write(msg)

    n_eval = max(1, len(pick))
    flip_audit = {
        "n": int(n_eval),
        "n_flips": len(flip_margins),
        "flip_rate": round(len(flip_margins) / n_eval, 5),
        "hi_conf_flips": int(sum(m >= HI_CONF_MARGIN for m in flip_margins)),
        "fp32_margin_threshold": HI_CONF_MARGIN,
        "fp32_margin_on_flips": _stats(flip_margins),
        "int8_p_max_on_flips": _stats(flip_int8_pmax),
        "flip_direction_matrix": flip_matrix.tolist(),   # [fp32类][int8类], 行列序=CLASS_NAMES
        "samples_capped_200": flip_records,
    }

    report = {
        "split": split, "n": int(len(pick)), "seed": args.seed,
        "labeled_mode": labeled_mode,
        "fp32_onnx": args.fp32, "int8_onnx": args.int8,
        "argmax_agree": round(agree / n_eval, 5),
        "flip_audit": flip_audit,
        "max_abs_logit_diff": round(diff_max, 5),
        "mean_abs_logit_diff": round(diff_sum / n_eval, 5),
        "class_names": C.CLASS_NAMES, "seconds": round(time.time() - t0),
    }
    if labeled_mode:
        m32, m8 = _metrics(cm32), _metrics(cm8)
        report.update({
            "fp32": m32, "int8": m8,
            "acc_delta": round(m8["acc"] - m32["acc"], 5),
            "severe_recall_delta": round(m8["severe_recall"] - m32["severe_recall"], 5),
            "confusion_fp32": cm32.tolist(), "confusion_int8": cm8.tolist(),
        })

    out = C.EVAL_RESULT_DIR / "int8_vs_fp32_report.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    # ---- 控制台 ----
    print("\n===== FP32 vs INT8 对比结果 =====")
    print(f"数据: {split}  n={report['n']}  耗时 {report['seconds']}s"
          f"  ({'带标注' if labeled_mode else '纯一致率模式'})")
    fa = flip_audit
    print(f"argmax 一致率: {report['argmax_agree']:.4f} | "
          f"翻转 {fa['n_flips']} (hi_conf {fa['hi_conf_flips']}, margin>={HI_CONF_MARGIN})")
    print("翻转方向矩阵 [fp32行 x int8列]:")
    for c, name in enumerate(C.CLASS_NAMES):
        print(f"  {name:<18}{fa['flip_direction_matrix'][c]}")
    if labeled_mode:
        print(f"{'':<16}{'FP32':>10}{'INT8':>10}{'差值':>10}")
        print(f"{'accuracy':<16}{m32['acc']:>10.4f}{m8['acc']:>10.4f}{report['acc_delta']:>+10.4f}")
        print(f"{'severe_recall':<16}{m32['severe_recall']:>10.4f}{m8['severe_recall']:>10.4f}"
              f"{report['severe_recall_delta']:>+10.4f}")
        for c, name in enumerate(C.CLASS_NAMES):
            print(f"{name + '_recall':<16}{m32['per_class_recall'][c]:>10.4f}"
                  f"{m8['per_class_recall'][c]:>10.4f}"
                  f"{m8['per_class_recall'][c] - m32['per_class_recall'][c]:>+10.4f}")
        verdict = ("✓ 达标(掉点<=2%)" if report["acc_delta"] >= -0.02
                   else "✗ 掉点超过2%, 按校准阶梯重试")
        print(f"结论: {verdict}")
    print(f"logit 平均差 {report['mean_abs_logit_diff']:.4f} / 最大差 {report['max_abs_logit_diff']:.4f}")
    if not labeled_mode:
        print("参考基线: test池3000张 95.1% / renamed 26张(全0桶) 34.6% / 验收线 98%")
    print(f"报告: {out}")


def softmax1d(logits):
    """1D 数值稳定 softmax"""
    e = np.exp(logits - logits.max())
    return e / e.sum()


def severity_logits(result):
    """ORT 输出 -> 1D severity logits (单头 [1,3] 压批; 双头 list 取 severity 分支)"""
    r = result[0] if isinstance(result, (tuple, list)) else result
    r = np.asarray(r)
    return r.reshape(-1) if r.ndim > 1 else r


def _stats(vals):
    if not vals:
        return None
    a = np.asarray(vals, dtype=float)
    return {"min": round(float(a.min()), 4), "median": round(float(np.median(a)), 4),
            "max": round(float(a.max()), 4)}


def _metrics(cm):
    tp = np.diag(cm).astype(float)
    gt = cm.sum(1).astype(float)
    rec = np.where(gt > 0, tp / np.maximum(gt, 1), 0.0)
    return {"acc": float(tp.sum() / max(1.0, cm.sum())),
            "per_class_recall": rec.tolist(),
            "severe_recall": float(rec[-1])}


if __name__ == "__main__":
    main()
