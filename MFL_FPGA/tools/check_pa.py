#!/usr/bin/env python3
"""check_pa.py -- verify the PA bitstream inside a Pango Booter BOOT_PG.bin.

Usage:
  python check_pa.py <new.sbit> <out_dbg3/BOOT_PG.bin>

Booter stores the PA .sbit with a 32-bit word-internal byte swap
(sbit[i:i+4][::-1] concatenated). This script searches that pattern in the
package and also checks the historical fixed offset 0x1B800.
"""
import sys

def main():
    if len(sys.argv) != 3:
        print("usage: python check_pa.py <new.sbit> <BOOT_PG.bin>")
        return 2
    sbit_path, img_path = sys.argv[1], sys.argv[2]
    sbit = open(sbit_path, "rb").read()
    img = open(img_path, "rb").read()
    flipped = b"".join(sbit[i:i + 4][::-1] for i in range(0, len(sbit), 4))
    idx = img.find(flipped)
    print("sbit=%d bytes  image=%d bytes  flipped=%d bytes" %
          (len(sbit), len(img), len(flipped)))
    if idx < 0:
        print("[FAIL] PA bitstream pattern NOT found in package")
        return 1
    print("[ok] PA bitstream found at 0x%X" % idx)
    off = 0x1B800
    inside = img[off:off + len(flipped)] == flipped
    print("fixed 0x1B800 match: %s" % ("yes" if inside else "no"))
    if not inside:
        print("[warn] offset differs; the package is still valid if found_at is sane")
    return 0

if __name__ == "__main__":
    sys.exit(main())
