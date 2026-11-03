import numpy as np
import json

QE = r'C:\Users\21889\Desktop\quant_export\quant_export'
TV = r'C:\Users\21889\Desktop\test_vectors\test_vectors\sample_0_Train_A_0000053'

cl = json.load(open(QE + r'\quant_params.json'))['conv_layers'][0]
sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']
w = np.load(QE + r'\weights_int8\conv00_w_int8.npy').astype(np.float64)
b = np.load(QE + r'\weights_int8\conv00_b_int32.npy').astype(np.float64)
x = np.load(TV + r'\conv00_in_int8.npy')[0].astype(np.float64)
yf = np.load(TV + r'\conv00_out_f32.npy')[0].astype(np.float64)

R0, C0, PS = 200, 400, 32
xp = np.pad(x, ((0,0),(1,1),(1,1)))[:, R0:R0+PS+2, C0:C0+PS+2]

# 设计矩阵: 每像素 27 个 tap (ic,k,l) + 常数 1
A = np.zeros((PS*PS, 28))
idx = 0
cols = []
for ic in range(3):
    for k in range(3):
        for l in range(3):
            A[:, idx] = xp[ic, k:k+PS, l:l+PS].ravel()
            cols.append((ic, k, l))
            idx += 1
A[:, 27] = 1.0

acc_true = yf[:, R0:R0+PS, C0:C0+PS] / (s_in * sw[:, None, None])   # 反解 acc
print('acc_true[0] range: [%.0f, %.0f]' % (acc_true[0].min(), acc_true[0].max()))

# 只在中心区域求解, 避开 padding 边界可能的口径差异
for c in range(2):
    y = acc_true[c].ravel()
    sol, res, rank, sv = np.linalg.lstsq(A, y, rcond=None)
    w_eff = sol[:27].reshape(3, 3, 3)                 # (ic,k,l)
    b_eff = sol[27]
    w_json = w[c]                                      # (ic,k,l) int8
    diff = w_eff - w_json
    print('ch%d: b_eff=%9.1f  b_json=%9.1f  |w_eff-w_json| mean=%.2f max=%.2f  |w_json| mean=%.2f'
          % (c, b_eff, b[c], np.abs(diff).mean(), np.abs(diff).max(), np.abs(w_json).mean()))
    print('   w_eff[:2,:,:] =', np.round(w_eff[:2], 1))
    print('   w_json[:2,:,:]=', w_json[:2])
    rat = np.where(np.abs(w_json) > 4, w_eff / w_json, np.nan)
    print('   ratio(w_eff/w_json) median=%.3f  p10=%.3f  p90=%.3f'
          % (np.nanmedian(rat), np.nanpercentile(rat, 10), np.nanpercentile(rat, 90)))
