# -*- coding: utf-8 -*-
"""
从 tar 分卷流式预处理(不解压落地): python preprocess_tar.py --split-name train

逐成员读取 tar 内图像 -> BILINEAR 缩放到 1024x480 -> JPEG q95 写入缓存目录,
原始压缩包保持不动。分卷是"整包被切开"的未压缩 tar(无 .tar 后缀), 默认按文件名
顺序拼接成一个逻辑流读取(--no-concat 可改为逐卷独立处理)。
断点续跑: 输出文件已存在即跳过, 中断后重跑同一命令即可。

产出位置(默认): G:\\PipeMFL-240K\\cache\\train-cache | val-cache  <- 训练/评估/量化只读这里

示例:
  python preprocess_tar.py --split-name train --workers 8
  python preprocess_tar.py --split-name val
  python preprocess_tar.py --split-name train --limit 50          # 调试: 只处理 50 张
  python preprocess_tar.py --split-name train --tars "D:/其它卷/part_*" --out D:/cache
"""

import argparse
import io
import multiprocessing as mp
import tarfile
from glob import glob
from pathlib import Path

from PIL import Image
from tqdm import tqdm

import config as C
from dataset import _RESIZE_FILTERS

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".bmp"}
BATCH = 128   # 每批派发给进程池的成员数, 控制内存积压(约 128x1.4MB)


def convert_bytes(job):
    """子进程: 压缩包内图像字节 -> 缩放 -> 落盘缓存"""
    data, dst = job
    dst = Path(dst)
    if dst.exists():
        return "skip"
    try:
        img = Image.open(io.BytesIO(data)).convert("RGB")
        if img.size != (C.INPUT_WIDTH, C.INPUT_HEIGHT):
            img = img.resize((C.INPUT_WIDTH, C.INPUT_HEIGHT), _RESIZE_FILTERS[C.RESIZE_INTERPOLATION])
        if dst.suffix.lower() == ".png":
            img.save(dst, "PNG")
        else:
            img.save(dst, "JPEG", quality=C.CACHE_JPEG_QUALITY)
        return "ok"
    except Exception as e:
        return f"error: {dst.name}: {e}"


class MultiFileReader(io.RawIOBase):
    """把多个分卷文件按顺序拼成一个只读前向流, 供 tarfile 以流模式读取"""

    def __init__(self, paths):
        self.files = [open(p, "rb") for p in paths]
        self.sizes = []
        for f in self.files:
            f.seek(0, 2)
            self.sizes.append(f.tell())
            f.seek(0)
        self.idx = 0
        self.pos = 0

    def readable(self):
        return True

    def read(self, n=-1):
        parts = []
        while n != 0:
            while self.idx < len(self.files) and self.files[self.idx].tell() >= self.sizes[self.idx]:
                self.idx += 1
            if self.idx >= len(self.files):
                break
            req = n if n < 0 else n - sum(map(len, parts))
            if req <= 0:          # 防御: tarfile 收尾跳过时可能传入超请求数, 视为流结束
                break
            chunk = self.files[self.idx].read(req)
            if not chunk:
                self.idx += 1
                continue
            parts.append(chunk)
            self.pos += len(chunk)
            if n > 0:
                n -= len(chunk)
        return b"".join(parts)

    def readinto(self, b):
        data = self.read(len(b))
        b[:len(data)] = data
        return len(data)

    def seek(self, offset, whence=0):
        if whence == 1:
            offset += self.pos
        elif whence == 2:
            raise OSError("MultiFileReader 不支持从末尾定位")
        if offset < self.pos:
            raise OSError("MultiFileReader 不支持回退(tar 流模式不需要)")
        while self.pos < offset:            # 前向跳过
            if not self.read(min(1 << 20, offset - self.pos)):
                break
        return self.pos

    def tell(self):
        return self.pos

    def close(self):
        for f in self.files:
            f.close()
        super().close()


def iter_members(tf):
    """产出 (图像字节, 成员名); 只取图像文件(卷内的 labels txt / coco json 天然被过滤)"""
    for member in tf:
        if not member.isfile():
            continue
        if Path(member.name).suffix.lower() not in IMAGE_EXTS:
            continue
        f = tf.extractfile(member)
        if f is None:
            continue
        yield f.read(), member.name


def resolve_volumes(args):
    """命令行 --tars 优先, 否则按 split-name 从 config 读卷 glob; 返回排序后的存在文件列表"""
    pattern = None
    if args.tars:
        pattern = args.tars if len(args.tars) > 1 else args.tars[0]
        if len(args.tars) > 1:                       # 显式给了多个具体路径
            return [p for p in args.tars if Path(p).exists()], True
    else:
        cfg_map = {"train": C.TRAIN_TAR_VOLUMES, "val": C.VAL_TAR_VOLUMES,
                   "test": C.TEST_TAR_VOLUMES}
        pattern = cfg_map.get(args.split_name)
        if not pattern:
            raise SystemExit(f"config 中 {args.split_name} 的 tar 卷未配置(TEST 分卷被截断?)")
    files = sorted(glob(str(pattern)))
    if not files:
        raise SystemExit(f"找不到分卷: {pattern}")
    return files, True


def check_header(first_volume):
    """轻量校验第一个卷的头部, 给出友好提示而不是让 tarfile 报天书"""
    with open(first_volume, "rb") as f:
        head = f.read(600)
    if head[:2] == b"\x1f\x8b":
        print("[tar] 头部检查: gzip 压缩流")
    elif len(head) >= 262 and head[257:262] == b"ustar":
        print("[tar] 头部检查: 未压缩 tar ✓")
    else:
        print("[警告] 首卷头部不像 tar/gzip, 若报错请确认分卷完整且顺序正确")


def main():
    ap = argparse.ArgumentParser(description="tar 分卷流式预处理(不解压落地)")
    ap.add_argument("--split-name", required=True, choices=["train", "val", "test"],
                    help="处理哪个数据集(决定 config 里的卷与缓存子目录)")
    ap.add_argument("--tars", nargs="+", default=None,
                    help="覆盖 config: tar 卷路径或通配符(默认从 config 读)")
    ap.add_argument("--out", default=None, help="输出根目录(默认 config.CACHE_ROOT)")
    ap.add_argument("--workers", type=int, default=min(8, mp.cpu_count()))
    ap.add_argument("--format", choices=["jpeg", "png"], default=C.CACHE_FORMAT)
    ap.add_argument("--quality", type=int, default=C.CACHE_JPEG_QUALITY)
    ap.add_argument("--limit", type=int, default=0, help=">0 时最多处理 N 张(调试用)")
    ap.add_argument("--no-concat", action="store_true",
                    help="逐卷独立处理(默认按文件名顺序拼接成一个逻辑 tar 流)")
    args = ap.parse_args()

    tars, _ = resolve_volumes(args)
    sizes = [Path(p).stat().st_size for p in tars]
    print(f"[卷] {len(tars)} 个, 共 {sum(sizes)/2**30:.1f} GiB:")
    for p, s in zip(tars, sizes):
        print(f"     {Path(p).name:<24}{s/2**30:8.2f} GiB")
    print(f"[预计] 144K 张约 2~4 小时 / 48K 张约 1~1.5 小时(8 workers, 受磁盘速度主导); "
          f"断点续跑: 中断后重跑同一命令")
    if not args.no_concat:
        check_header(tars[0])

    out_dir = Path(args.out or C.CACHE_ROOT) / C.CACHE_SPLIT_NAMES[args.split_name]
    out_dir.mkdir(parents=True, exist_ok=True)
    ext = ".png" if args.format == "png" else ".jpg"
    if args.format != C.CACHE_FORMAT:
        print(f"[提示] --format={args.format} 与 config.CACHE_FORMAT='{C.CACHE_FORMAT}' 不一致, "
              f"训练读缓存会找不到文件!")

    stats = {"ok": 0, "skip": 0, "error": 0, "dup": 0}
    seen = set()
    pool = mp.Pool(args.workers)

    def drain(buf):
        for r in pool.imap_unordered(convert_bytes, buf):
            if r.startswith("error"):
                stats["error"] += 1
                print(" ", r)
            else:
                stats[r] += 1

    def handle(data, name):
        stem = Path(name).stem
        if stem in seen:                     # 跨卷重名: 保留先出现的
            stats["dup"] += 1
            return
        if args.limit and stats["ok"] + stats["skip"] + len(buf) >= args.limit:
            return                           # 精确截断: 不超过 --limit
        seen.add(stem)
        buf.append((data, str(out_dir / (stem + ext))))
        if len(buf) >= BATCH:
            drain(buf)
            pbar.update(len(buf))
            buf.clear()

    def finish(buf, pbar):
        if buf:
            drain(buf)
            pbar.update(len(buf))
            buf.clear()
        pbar.close()

    def enough():
        return args.limit and stats["ok"] + stats["skip"] >= args.limit

    if args.no_concat:
        for tp in tars:
            print(f"[tar] {Path(tp).name} -> {out_dir}")
            buf, pbar = [], tqdm(ncols=70, unit="img")
            with tarfile.open(tp, mode="r|*") as tf:
                for data, name in iter_members(tf):
                    handle(data, name)
                    if enough():
                        break
            finish(buf, pbar)
            if enough():
                break
    else:
        buf, pbar = [], tqdm(total=args.limit or None, ncols=70, unit="img")
        reader = MultiFileReader(tars)
        print(f"[tar] {len(tars)} 卷按序拼接为一条流 -> {out_dir}")
        tf = tarfile.open(fileobj=reader, mode="r|*")
        try:
            for data, name in iter_members(tf):
                handle(data, name)
                if enough():
                    break
        finally:
            try:
                tf.close()       # 提前退出时跳过剩余成员, 收尾异常可忽略
            except (ValueError, OSError, EOFError) as e:
                print(f"[提示] tar 流收尾跳过({type(e).__name__}), 已处理数据不受影响")
            reader.close()
            finish(buf, pbar)
    pool.close()
    pool.join()

    print(f"[完成] ok={stats['ok']} skip={stats['skip']} dup={stats['dup']} "
          f"error={stats['error']} -> {out_dir}")


if __name__ == "__main__":
    main()
