# -*- coding: utf-8 -*-
"""
训练: python train.py [--epochs 30] [--batch-size 16] [--max-samples N] [--resume] [--cpu]
- GPU 硬校验: 检测不到 CUDA 直接报错并给修复指引(绝不静默回退 CPU)
- bf16 AMP(4060 Ada 支持) + channels_last + AdamW + warmup/cosine + 加权交叉熵+标签平滑
- best 模型按 0.7*severe_recall + 0.3*val_acc 选择; 支持断点续训
"""

import argparse
import csv
import json
import random
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from torch.amp import GradScaler, autocast

import config as C
import model as M
from dataset import build_data


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
def seed_everything(seed):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


@torch.no_grad()
def confusion(model, loader, device):
    """返回 (混淆矩阵[n,n], 平均loss, 类型统计或None). label<0 的样本(无标注)自动跳过."""
    model.eval()
    num_cls = model.num_classes
    has_type = model.type_head
    cm = np.zeros((num_cls, num_cls), dtype=np.int64)
    type_stats = np.zeros((2, 3), dtype=np.int64) if has_type else None   # 每标签 [tp, fp, fn]
    crit = nn.CrossEntropyLoss(reduction="sum")
    bce = nn.BCEWithLogitsLoss(reduction="sum") if has_type else None
    total_loss, seen = 0.0, 0
    for batch in loader:
        imgs, labels = batch[0], batch[1]
        aux = batch[2] if len(batch) > 2 else None
        mask = labels >= 0
        if not mask.any():
            continue
        imgs = imgs[mask].to(device, non_blocking=True)
        labels = labels[mask].to(device, non_blocking=True)
        out = model(imgs)
        cls_logits, type_logits = out if model.type_head else (out, None)
        loss = crit(cls_logits, labels)
        if has_type and aux is not None:
            aux = aux[mask].to(device, non_blocking=True)
            loss = loss + C.TYPE_LOSS_LAMBDA * bce(type_logits, aux)
            pred = (torch.sigmoid(type_logits) > 0.5).cpu().numpy()
            gt = aux.cpu().numpy().astype(int)
            for k in range(2):
                type_stats[k, 0] += int(((pred[:, k] == 1) & (gt[:, k] == 1)).sum())
                type_stats[k, 1] += int(((pred[:, k] == 1) & (gt[:, k] == 0)).sum())
                type_stats[k, 2] += int(((pred[:, k] == 0) & (gt[:, k] == 1)).sum())
        total_loss += loss.item()
        seen += labels.numel()
        cm += np.bincount(num_cls * labels.cpu().numpy() + cls_logits.argmax(1).cpu().numpy(),
                          minlength=num_cls * num_cls).reshape(num_cls, num_cls)
    return cm, (total_loss / max(1, seen)), type_stats


def metrics_from_type(type_stats):
    """腐蚀类型存在性(MTL/CRC)的 P/R/F1"""
    names = ["MTL", "CRC"]
    out = {}
    for k, name in enumerate(names):
        tp, fp, fn = (float(v) for v in type_stats[k])
        prec = tp / max(1.0, tp + fp)
        rec = tp / max(1.0, tp + fn)
        f1 = 2 * prec * rec / max(1e-9, prec + rec)
        out[name] = {"precision": round(prec, 4), "recall": round(rec, 4), "f1": round(f1, 4)}
    return out


def metrics_from_cm(cm):
    """acc / 每类 P,R,F1 / macro-F1 / severe_recall"""
    num_cls = cm.shape[0]
    tp = np.diag(cm).astype(np.float64)
    pred = cm.sum(0).astype(np.float64)
    gt = cm.sum(1).astype(np.float64)
    with np.errstate(divide="ignore", invalid="ignore"):
        prec = np.where(pred > 0, tp / pred, 0.0)
        rec = np.where(gt > 0, tp / gt, 0.0)
        f1 = np.where(prec + rec > 0, 2 * prec * rec / (prec + rec), 0.0)
    return {
        "acc": float(tp.sum() / max(1.0, cm.sum())),
        "per_class_precision": prec.tolist(),
        "per_class_recall": rec.tolist(),
        "per_class_f1": f1.tolist(),
        "macro_f1": float(f1.mean()),
        "severe_recall": float(rec[-1]),   # 最后一类=severe
    }


def build_scheduler(optimizer, epochs, warmup, min_ratio):
    def fn(epoch):
        if epoch < warmup:
            return (epoch + 1) / max(1, warmup)
        t = (epoch - warmup) / max(1, epochs - warmup)
        return min_ratio + (1 - min_ratio) * 0.5 * (1 + np.cos(np.pi * min(1.0, t)))
    return torch.optim.lr_scheduler.LambdaLR(optimizer, fn)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=C.NUM_EPOCHS)
    ap.add_argument("--batch-size", type=int, default=C.BATCH_SIZE)
    ap.add_argument("--max-samples", type=int, default=C.MAX_TRAIN_SAMPLES, help=">0 冒烟用: 截断训练样本")
    ap.add_argument("--max-test", type=int, default=C.MAX_TEST_SAMPLES)
    ap.add_argument("--resume", action="store_true", help="从 output/models/last_model.pt 续训")
    ap.add_argument("--cpu", action="store_true", help="强制 CPU(调试用)")
    args = ap.parse_args()

    device = torch.device("cpu") if args.cpu else C.get_device()
    if device.type == "cuda":
        torch.backends.cudnn.benchmark = True
        print(f"[设备] {torch.cuda.get_device_name(0)} | bf16: {torch.cuda.is_bf16_supported()}")
    else:
        print("[设备] CPU (仅调试)")

    seed_everything(C.SEED)
    data = build_data(batch_size=args.batch_size,
                      max_train=args.max_samples, max_test=args.max_test)
    meta = data["meta"]
    print(f"[数据] train={meta['train_n']}  val={meta['val_n']}  test={meta['test_n']}"
          f"  (test {'有标签' if meta['test_labeled'] else '无标签, 仅推理'})")
    print(f"[标签分布] train={dict(zip(C.CLASS_NAMES, meta['train_counts']))}"
          f"  val={dict(zip(C.CLASS_NAMES, meta['val_counts']))}")
    print(f"[类权重] {np.round(data['class_w'], 3).tolist()}")

    model = M.MFLCNN().to(device)
    if C.CHANNELS_LAST and device.type == "cuda":
        model = model.to(memory_format=torch.channels_last)
    print(M.model_summary(model))

    crit = nn.CrossEntropyLoss(weight=torch.tensor(data["class_w"], device=device),
                               label_smoothing=C.LABEL_SMOOTHING)
    bce = None
    if C.ENABLE_TYPE_HEAD:
        n_pos = data["meta"].get("train_type_counts", {"MTL": 1, "CRC": 1})
        n_total = max(1, data["meta"]["train_n"])
        pw = [max(1.0, (n_total - n_pos["MTL"]) / max(1, n_pos["MTL"])),
              max(1.0, (n_total - n_pos["CRC"]) / max(1, n_pos["CRC"]))]
        bce = nn.BCEWithLogitsLoss(pos_weight=torch.tensor(pw, device=device))
        print(f"[类型头] 正类权重 MTL={pw[0]:.1f} CRC={pw[1]:.1f}, 损失权重 λ={C.TYPE_LOSS_LAMBDA}")
    optimizer = torch.optim.AdamW(model.parameters(), lr=C.LEARNING_RATE,
                                  weight_decay=C.WEIGHT_DECAY)
    scheduler = build_scheduler(optimizer, args.epochs, C.WARMUP_EPOCHS, C.MIN_LR_RATIO)

    amp_dtype, use_scaler = torch.bfloat16, False
    if device.type == "cuda" and C.AMP_DTYPE != "off":
        if C.AMP_DTYPE in ("auto", "bf16") and torch.cuda.is_bf16_supported():
            pass
        elif C.AMP_DTYPE in ("auto", "fp16"):
            amp_dtype, use_scaler = torch.float16, True
        else:
            amp_dtype = None
    scaler = GradScaler("cuda", enabled=use_scaler)

    best_score, start_epoch = -1.0, 0
    best_path, last_path = C.MODEL_DIR / "best_model.pt", C.MODEL_DIR / "last_model.pt"
    if args.resume and last_path.exists():
        ck = torch.load(last_path, map_location=device, weights_only=False)
        model.load_state_dict(ck["state_dict"])
        optimizer.load_state_dict(ck["optimizer"])
        scheduler.load_state_dict(ck["scheduler"])
        scaler.load_state_dict(ck["scaler"])
        start_epoch, best_score = ck["epoch"] + 1, ck["best_score"]
        print(f"[续训] 从 epoch {start_epoch} 恢复, best_score={best_score:.4f}")

    csv_path = C.LOG_DIR / "training_log.csv"
    type_cols = ["mtl_f1", "crc_f1"] if C.ENABLE_TYPE_HEAD else []
    if start_epoch == 0:
        with open(csv_path, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(
                ["epoch", "lr", "train_loss", "train_acc", "val_loss", "val_acc",
                 "severe_recall", "macro_f1", "score", "sec"] + type_cols)

    w_sev, w_acc = C.BEST_SCORE_SEVERE_RECALL_W, C.BEST_SCORE_ACC_W
    for epoch in range(start_epoch, args.epochs):
        t0 = time.time()
        model.train()
        run_loss, correct, seen = 0.0, 0, 0
        for i, batch in enumerate(data["train"]):
            imgs, labels = batch[0], batch[1]
            aux = batch[2] if len(batch) > 2 else None
            imgs = imgs.to(device, non_blocking=True)
            if C.CHANNELS_LAST and device.type == "cuda":
                imgs = imgs.to(memory_format=torch.channels_last)
            labels = labels.to(device, non_blocking=True)
            if aux is not None:
                aux = aux.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with autocast("cuda", dtype=amp_dtype, enabled=amp_dtype is not None and device.type == "cuda"):
                out = model(imgs)
                cls_logits, type_logits = out if model.type_head else (out, None)
                loss = crit(cls_logits, labels)
                if model.type_head and bce is not None:
                    loss = loss + C.TYPE_LOSS_LAMBDA * bce(type_logits, aux)
            scaler.scale(loss).backward()
            if C.GRAD_CLIP_NORM > 0:
                scaler.unscale_(optimizer)
                nn.utils.clip_grad_norm_(model.parameters(), C.GRAD_CLIP_NORM)
            scaler.step(optimizer)
            scaler.update()
            run_loss += loss.item() * labels.numel()
            correct += (cls_logits.argmax(1) == labels).sum().item()
            seen += labels.numel()
            if i % 50 == 0:
                print(f"  epoch {epoch+1} [{i*len(imgs):>6}/{len(data['train'].dataset)}] "
                      f"loss={loss.item():.4f}", end="\r")
        scheduler.step()

        cm, val_loss, type_stats = confusion(model, data["val"], device)
        m = metrics_from_cm(cm)
        score = w_sev * m["severe_recall"] + w_acc * m["acc"]
        dt = time.time() - t0
        tm = metrics_from_type(type_stats) if type_stats is not None else {}
        print(f"epoch {epoch+1}/{args.epochs} | train_loss={run_loss/max(1,seen):.4f} "
              f"train_acc={correct/max(1,seen):.4f} "
              f"| val_loss={val_loss:.4f} val_acc={m['acc']:.4f} "
              f"severe_recall={m['severe_recall']:.4f} macro_f1={m['macro_f1']:.4f} "
              f"| score={score:.4f} | {dt:.0f}s"
              + (f" | mtl_f1={tm.get('MTL',{}).get('f1','?')} crc_f1={tm.get('CRC',{}).get('f1','?')}" if tm else "")
              + (f" | 显存峰值{torch.cuda.max_memory_allocated()/2**20:.0f}MB" if device.type == "cuda" else ""))
        recalls = " ".join(f"{name.split('_')[0]}={r:.2f}" for name, r in
                           zip(C.CLASS_NAMES, m["per_class_recall"]))
        print(f"  per-class recall: {recalls}")

        with open(csv_path, "a", newline="", encoding="utf-8") as f:
            row = [epoch + 1, f"{scheduler.get_last_lr()[0]:.2e}",
                   round(run_loss / max(1, seen), 5), round(correct / max(1, seen), 5),
                   round(val_loss, 5), round(m["acc"], 5),
                   round(m["severe_recall"], 5), round(m["macro_f1"], 5),
                   round(score, 5), round(dt)]
            if type_cols:
                row += [tm.get("MTL", {}).get("f1", ""), tm.get("CRC", {}).get("f1", "")]
            csv.writer(f).writerow(row)
        ck = {"state_dict": model.state_dict(), "optimizer": optimizer.state_dict(),
              "scheduler": scheduler.state_dict(), "scaler": scaler.state_dict(),
              "epoch": epoch, "best_score": best_score, "metrics": m}
        torch.save(ck, last_path)
        if score > best_score:
            best_score = score
            M.save_model(model, best_path, extra={"epoch": epoch + 1, "score": score, "metrics": m})
            print(f"  ^ best 模型已更新 (score={score:.4f})")

    # ---- 收尾: 复验 best + 指标落盘 + FP32 ONNX ----
    print("[收尾] 加载 best 模型复验...")
    model, ck = M.load_model(best_path, device=device)
    if C.CHANNELS_LAST and device.type == "cuda":
        model = model.to(memory_format=torch.channels_last)
    cm, _, type_stats = confusion(model, data["val"], device)
    m = metrics_from_cm(cm)
    final = {"model": C.model_name(), "profile": C.MODEL_PROFILE, "epochs_trained": args.epochs,
             "best_score": best_score, "val": m,
             "confusion_matrix": cm.tolist(), "class_names": C.CLASS_NAMES,
             "type_head": model.type_head, "data": meta}
    if type_stats is not None:
        final["type_metrics"] = metrics_from_type(type_stats)
    (C.LOG_DIR / "final_metrics.json").write_text(json.dumps(
        final, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[最终] val_acc={m['acc']:.4f} severe_recall={m['severe_recall']:.4f} "
          f"macro_f1={m['macro_f1']:.4f} -> {C.LOG_DIR / 'final_metrics.json'}")
    M.export_fp32_onnx(model.cpu(), C.MODEL_DIR / f"{C.model_name()}_fp32.onnx")


if __name__ == "__main__":
    main()
