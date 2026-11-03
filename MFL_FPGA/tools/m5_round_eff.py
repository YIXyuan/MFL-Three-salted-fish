import numpy as np
import json

QE = r'C:\Users\21889\Desktop\quant_export\quant_export'
TV = r'C:\Users\21889\Desktop\test_vectors\test_vectors\sample_0_Train_A_0000053'
mf = json.load(open(TV + r'\..\manifest.json', encoding='utf-8'))
cin_s = np.array(mf['conv_in_scale']); cout_s = np.array(mf['conv_out_scale'])

# --- 0) 张量链语义检查 ---
c01in = np.load(TV + r'\conv01_in_int8.npy')[0].astype(np.int64)
c00out = np.load(TV + r'\conv00_out_int8.npy')[0].astype(np.int64)
print('conv01_in: neg count =', int((c01in < 0).sum()), '/', c01in.size,
      ' range [%d,%d]' % (c01in.min(), c01in.max()))
print('conv00_out: neg count =', int((c00out < 0).sum()), '/', c00out.size)
# relu(c00out) 重整化到 conv01_in 域
rl = np.maximum(c00out, 0).astype(np.float64) * cout_s[0]          # →float 值
pred = np.round(rl / cin_s[1]).astype(np.int64)
d = pred - c01in
print('conv01_in vs round(relu(conv00_out)*%0.4f/%0.4f): exact=%.2f%% |d|<=1=%.2f%%'
      % (cout_s[0], cin_s[1], 100.0*(d == 0).mean(), 100.0*(np.abs(d) <= 1).mean()))

# --- 1) 用最小二乘解出"向量域"的 acc, 定舍入口径 ---
cl = json.load(open(QE + r'\quant_params.json'))['conv_layers'][0]
sw = np.array(cl['weight_scale']); s_in = cl['act_in_scale']
w = np.load(QE + r'\weights_int8\conv00_w_int8.npy').astype(np.float64)
x = np.load(TV + r'\conv00_in_int8.npy')[0].astype(np.float64)
yf = np.load(TV + r'\conv00_out_f32.npy')[0].astype(np.float64)
y8 = np.load(TV + r'\conv00_out_int8.npy')[0].astype(np.int64)

R0, C0, PS = 200, 400, 32
xp = np.pad(x, ((0,0),(1,1),(1,1)))[:, R0:R0+PS+2, C0:C0+PS+2]
A = np.zeros((PS*PS, 28))
idx = 0
for ic in range(3):
    for k in range(3):
        for l in range(3):
            A[:, idx] = xp[ic, k:k+PS, l:l+PS].ravel(); idx += 1
A[:, 27] = 1.0

exact_f, exact_r, exact_fh = [], [], []
for c in range(16):
    yt = yf[c, R0:R0+PS, C0:C0+PS].ravel()
    sol, *_ = np.linalg.lstsq(A, yt, rcond=None)
    acc_eff = A @ sol                                   # 向量域的 acc(含 bias 项)
    yf_pred = (A[:, :27] @ sol[:27]).reshape(PS, PS) + sol[27]   # 即 acc_eff 重塑
    # alpha: yf ≈ alpha * acc_eff (归一, 消除域差)
    alpha = (acc_eff @ yt) / (acc_eff @ acc_eff)
    yfit = alpha * acc_eff
    resid = yt - yfit
    # 量化: 除以 s_out(=tf scale, 已与 qp 对齐) 三种口径
    q_f  = np.clip(np.floor(yf_pred*alpha / cout_s[0]), -128, 127)
    q_r  = np.clip(np.round(yf_pred*alpha / cout_s[0]), -128, 127)       # half-even
    q_fh = np.clip(np.floor(yf_pred*alpha / cout_s[0] + 0.5), -128, 127) # half-up(整数域同款)
    t = y8[c, R0:R0+PS, C0:C0+PS].astype(np.int64)                       # (PS,PS)
    exact_f.append((q_f.astype(np.int64) == t).mean())
    exact_r.append((q_r.astype(np.int64) == t).mean())
    exact_fh.append((q_fh.astype(np.int64) == t).mean())
    if c < 3:
        print('ch%d: resid std(f32)=%.4f  alpha=%.6f  exact floor=%.1f%% round(he)=%.1f%% half-up=%.1f%%'
              % (c, resid.std(), alpha, 100*exact_f[-1], 100*exact_r[-1], 100*exact_fh[-1]))

print('ALL: floor=%.2f%%  round-half-even=%.2f%%  round-half-up=%.2f%%'
      % (100*np.mean(exact_f), 100*np.mean(exact_r), 100*np.mean(exact_fh)))
