import numpy as np
import json

QE = r'C:\Users\21889\Desktop\quant_export\quant_export'
TV = r'C:\Users\21889\Desktop\test_vectors\test_vectors\sample_0_Train_A_0000053'

cl = json.load(open(QE + r'\quant_params.json'))['conv_layers'][0]
sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']; s_out = cl['act_out_scale']
w = np.load(QE + r'\weights_int8\conv00_w_int8.npy').astype(np.int64)
b = np.load(QE + r'\weights_int8\conv00_b_int32.npy').astype(np.int64)
x = np.load(TV + r'\conv00_in_int8.npy')[0].astype(np.int64)
yf = np.load(TV + r'\conv00_out_f32.npy')[0].astype(np.float64)

R0, C0, PS = 200, 400, 32
xp = np.pad(x, ((0,0),(1,1),(1,1)))[:, R0:R0+PS+2, C0:C0+PS+2]
acc_nb = np.zeros((16, PS, PS), dtype=np.int64)
for k in range(3):
    for l in range(3):
        acc_nb += np.tensordot(w[:, :, k, l], xp[:, k:k+PS, l:l+PS], axes=([1], [0]))

reff = yf[:, R0:R0+PS, C0:C0+PS]
acc_true = reff / (s_in * sw[:, None, None])          # 反解 acc(真值域)
bias_est = acc_true - acc_nb                           # 每像素的反解 bias

for c in range(4):
    e = bias_est[c].ravel()
    print('ch%d: bias_est mean=%9.1f std=%7.1f | json_b=%8d  -json_b=%8d  ratio=%6.3f'
          % (c, e.mean(), e.std(), b[c], -b[c], e.mean() / (b[c] if b[c] != 0 else 1)))

# 全通道汇总
em = np.array([bias_est[c].mean() for c in range(16)])
es = np.array([bias_est[c].std()  for c in range(16)])
print('all-ch: mean(bias_est)=', np.round(em, 1))
print('all-ch: std(bias_est) =', np.round(es, 1))
print('all-ch: json b        =', b)
print('corr(bias_est, b) =', np.corrcoef(em, b)[0, 1])
print('corr(bias_est, -b)=', np.corrcoef(em, -b)[0, 1])
