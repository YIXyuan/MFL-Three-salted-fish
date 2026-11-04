# -*- coding: utf-8 -*-
"""
评估: python evaluate.py [--model output/models/best_model.pt] [--max-test N]
- 测试集有标签: 完整指标(acc/每类P-R-F1/macro-F1/severe-recall) + 混淆矩阵图 + test_report.json
- 测试集无标签(当前试训练状态): 输出测试集预测分布 CSV, 并改用验证集出指标
"""

import argparse
import csv
import json
from pathlib import Path

import numpy as np
import torch

import config as C
import model as M
from dataset import build_data
from train import confusion, metrics_from_cm


def save_confusion_png(cm, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, ax = plt.subplots(figsize=(5, 4.5))
    im = ax.imshow(cm, cmap="Blues")
    ax.set_xticks(range(len(C.CLASS_NAMES)), C.CLASS_NAMES, rotation=20, ha="right")
    ax.set_yticks(range(len(C.CLASS_NAMES)), C.CLASS_NAMES)
    for i in range(cm.shape[0]):
        for j in range(cm.shape[1]):
            ax.text(j, i, str(cm[i, j]), ha="center", va="center",
                    color="white" if cm[i, j] > cm.max() / 2 else "black")
    ax.set_xlabel("预测"), ax.set_ylabel("真实"), ax.set_title("Confusion Matrix")
    fig.colorbar(im, shrink=0.8)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


@torch.no_grad()
def predict_dump(model, loader, device, out_csv):
    """无标签测试集: 逐样本输出预测与三分类概率 (loader 不 shuffle, 顺序即数据集顺序)"""
    model.eval()
    rows, probs_all = [], np.zeros(len(C.CLASS_NAMES), dtype=np.int64)
    for imgs, *_ in loader:
        out = model(imgs.to(device))
        cls_logits = out[0] if isinstance(out, (tuple, list)) else out
        probs = torch.softmax(cls_logits, 1).cpu().numpy()
        for pred in probs.argmax(1):
            probs_all[pred] += 1
        rows.extend(probs.tolist())
    with open(out_csv, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["image", "pred"] + [f"p_{n}" for n in C.CLASS_NAMES])
        for i, r in enumerate(rows):
            w.writerow([Path(loader.dataset.image_paths[i]).name,
                        C.CLASS_NAMES[int(np.argmax(r))]]
                       + [round(float(x), 5) for x in r])
    return probs_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(C.MODEL_DIR / "best_model.pt"))
    ap.add_argument("--max-test", type=int, default=0)
    ap.add_argument("--split", default=None, choices=["test", "val"],
                    help="评估哪个 split(默认: 有测试集用 test, 否则用 val)")
    args = ap.parse_args()

    device = C.get_device()
    model, ck = M.load_model(args.model, device=device)
    if tuple(model.profile) != tuple(C.MODEL_PROFILE):
        print(f"[警告] 模型配比 {model.profile} != 当前 config {C.MODEL_PROFILE}, 以模型为准")
    print(f"[模型] {args.model} (epoch {ck.get('epoch', '?')}, score {ck.get('score', '?')}"
          + f", type_head={model.type_head})")

    data = build_data(max_test=args.max_test)
    report = {"model": str(args.model), "profile": model.profile,
              "class_names": C.CLASS_NAMES, "type_head": model.type_head}

    # ---- 选择评估 split: 显式指定 > 有标签测试集 > 官方 val ----
    if args.split:
        target = args.split
    else:
        target = "test" if data["meta"]["test_labeled"] else "val"

    if target == "test" and data["meta"]["test_n"] == 0:
        print("[提示] 测试集未配置(test 分卷被截断/未下载), 回退评估 val")
        target = "val"

    if target == "test" and data["meta"]["test_n"] > 0:
        if not data["meta"]["test_labeled"]:
            dist = predict_dump(model, data["test"], device,
                                C.EVAL_RESULT_DIR / "test_predictions.csv")
            print(f"[测试集] 无标签, 已输出 {data['meta']['test_n']} 条预测 -> test_predictions.csv")
            print("  预测分布:", dict(zip(C.CLASS_NAMES, dist.tolist())))
            report["test_pred_distribution"] = dict(zip(C.CLASS_NAMES, dist.tolist()))
            target = "val"      # 指标改由 val 出
        else:
            loader, tag = data["test"], "test"
    if target == "val":
        loader, tag = data["val"], "val"

    cm, loss, type_stats = confusion(model, loader, device)
    m = metrics_from_cm(cm)
    print(f"[{tag}集 n={len(loader.dataset)}] acc={m['acc']:.4f} severe_recall={m['severe_recall']:.4f} "
          f"macro_f1={m['macro_f1']:.4f}")
    print("  每类 recall:", dict(zip(C.CLASS_NAMES, np.round(m["per_class_recall"], 4))))
    save_confusion_png(cm, C.EVAL_RESULT_DIR / f"confusion_matrix_{tag}.png")
    report[tag] = {**m, "confusion_matrix": cm.tolist(), "loss": loss}
    if type_stats is not None:
        tm = metrics_from_type(type_stats)
        report["type_metrics"] = tm
        print("  腐蚀类型存在性:", json.dumps(tm, ensure_ascii=False))

    out = C.EVAL_RESULT_DIR / "test_report.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[报告] {out}")


if __name__ == "__main__":
    main()
