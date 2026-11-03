# -*- coding: utf-8 -*-
"""
mfl_resize_1024x480.py -- MFL 管线 PC 端预处理（原图 -> 板端可用输入）

原始 MFL 伪彩图(如 5000x2400) --BILINEAR--> 1024x480 JPEG。
/255 归一化不需要单独做: 板端/模型量化是 q = v>>1（等价 scale=1/127），
BILINEAR 之后直接存 JPEG 即可, 板端 stb 解码 + v>>1 就是模型输入。

命名: 源文件名末尾的数字作为 point_id（Train_A_0000053.png -> P0053_001.jpg）,
保留与模型侧标签的可映射性; 没有数字的文件退化为 --start 顺序编号。
注意 app_arm 的 point_id 校验是 1..1861: 编号 >1861 的图会被处理但结果不落地,
5 位数编号会被 point_id_from_name 截成前 4 位（身份错乱）——映射 CSV 的
usable 列标注了每张能否走完结果路径。

用法:
  python mfl_resize_1024x480.py <原图...> -o <输出目录> [--start 1]

同时在输出目录写 _map.csv: new_name,old_name,point_id,usable。

依赖: pip install pillow
"""
import argparse
import os
import re
import sys

from PIL import Image, ImageOps

W, H = 1024, 480
PID_MAX = 1861          # app_arm point_id_from_name 的上限（main.c 写死）


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+', help='原始图（任意尺寸，建议 5000x2400）')
    ap.add_argument('-o', '--out', required=True, help='输出目录')
    ap.add_argument('--start', type=int, default=1, help='无编号文件的起始编号（默认 1）')
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    idx = a.start
    n_ok = 0
    map_rows = ['new_name,old_name,point_id,usable']
    for src in a.images:
        if os.path.isdir(src):
            continue
        im = Image.open(src)
        im = ImageOps.exif_transpose(im).convert('RGB')
        if im.size != (W, H):
            im = im.resize((W, H), Image.BILINEAR)

        m = re.search(r'(\d+)\.\w+$', os.path.basename(src))
        if m:
            pid = int(m.group(1))
        else:
            pid = idx
            idx += 1
        new_name = 'P%04d_001.jpg' % pid
        usable = 1 if 1 <= pid <= PID_MAX else 0
        out = os.path.join(a.out, new_name)
        im.save(out, 'JPEG', quality=95)
        map_rows.append('%s,%s,P%04d,%d' % (new_name, os.path.basename(src), pid, usable))
        n_ok += 1
    with open(os.path.join(a.out, '_map.csv'), 'w', newline='\n') as f:
        f.write('\n'.join(map_rows) + '\n')
    print('[ok] %d 张 -> %s（映射表 _map.csv）' % (n_ok, a.out))


if __name__ == '__main__':
    main()
