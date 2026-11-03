import numpy as np

rows = []
for line in open(r'C:\Users\21889\Desktop\Kosmo2_MES2K100\ip\kosmo2_pe_layer\sim\vec\t0_in.hex'):
    line = line.strip()
    if line:
        rows.append(bytes.fromhex(line))
img = np.array([list(r) for r in rows], dtype=np.uint8)
print('img shape', img.shape)
got = bytes.fromhex('000b6b6232541300')
gotn = np.frombuffer(got, dtype=np.uint8)
print('got =', list(gotn))
flat = img.ravel()
for i in range(len(flat) - len(gotn) + 1):
    if np.array_equal(flat[i:i + len(gotn)], gotn):
        print('MATCH full at flat', i, '-> row(c*H+y)', i // 16, 'x from', i % 16)
for i in range(len(flat) - 4):
    if np.array_equal(flat[i:i + 4], gotn[:4]):
        print('first-4 match at flat', i, 'row', i // 16, 'x', i % 16)
for r in range(4):
    print('row', r, list(img[r]))
