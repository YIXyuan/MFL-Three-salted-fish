import numpy as np
import json

QE = r'C:\Users\21889\Desktop\quant_export\quant_export'
TV = r'C:\Users\21889\Desktop\test_vectors\test_vectors\sample_0_Train_A_0000053'

cl = json.load(open(QE + r'\quant_params.json'))['conv_layers'][0]
sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']
w = np.load(QE + r'\weights_int8\conv00_w_int8.npy').astype(np.int64)
b = np.load(QE + r'\weights_int8\conv00_b_int32.npy').astype(np.int64)
x = np.load(TV + r'\conv00_in_int8.npy')[0].astype(np.int64)
yf = np.load(TV + r'\conv00_out_f32.npy')[0].astype(np.float64)
y8 = np.load(TV + r'\conv00_out_int8.npy')[0].astype(np.int64)

R0, C0, PS = 200, 400, 16
xp = np.pad(x, ((0,0),(1,1),(1,1)))[:, R0:R0+PS+2, C0:C0+PS+2]

def conv_acc(w4, mode):
    acc = np.zeros((16, PS, PS), dtype=np.int64)
    for k in range(3):
        for l in range(3):
            if mode == 'OIKL':      # (OC, IC, KH, KW)
                wk = w4[:, :, k, l]
            else:                   # (OC, KH, KW, IC)
                wk = w4[:, k, l, :]
            acc += np.tensordot(wk, xp[:, k:k+PS, l:l+PS], axes=([1],[0]))
    return acc

for mode in ('OIKL', 'OKLI'):
    acc = conv_acc(w, mode)
    for with_bias in (True, False):
        a = acc + (b[:, None, None] if with_bias else 0)
        af = a * (s_in * sw[:, None, None])
        reff = yf[:, R0:R0+PS, C0:C0+PS]
        err = np.abs(af - reff)
        print('%-5s bias=%-5s  max|err|=%8.3f  mean|err|=%7.3f  px00: acc_f=%.4f yf=%.4f'
              % (mode, str(with_bias), err.max(), err.mean(), af[0,0,0], reff[0,0,0]))

# 参考: 若 acc 只差一个比例因子, 该因子随像素是否恒定
acc1 = conv_acc(w, 'OIKL') + b[:, None, None]
af1 = acc1 * (s_in * sw[:, None, None])
reff = yf[:, R0:R0+PS, C0:C0+PS]
m = np.abs(af1) > 1e-6
ratio = reff[m] / af1[m]
print('OIKL ratio yf/acc_f: mean=%.3f median=%.3f p5=%.3f p95=%.3f'
      % (ratio.mean(), np.median(ratio), np.percentile(ratio, 5), np.percentile(ratio, 95)))
