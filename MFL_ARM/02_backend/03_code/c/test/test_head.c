#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>
#include "head.h"
#include "quant_params.h"

#define N_FEAT  (FEAT_C * FEAT_H * FEAT_W)
#define N_CASES 32
#define TOL_LOGITS 0.10f
#define TOL_GAP    1e-4f
#define TOL_FC1    2e-3f

static int g_fail = 0;

static void fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("    [FAIL] ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    g_fail++;
}

static int read_bin(const char *path, void *buf, size_t expect)
{
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(buf, 1, expect, f);
    int extra = fgetc(f);
    fclose(f);
    return (n == expect && extra == EOF) ? 0 : -2;
}

static double now_ms(void)
{
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int json_vec3(const char *json, const char *key, float out[3])
{
    const char *p = strstr(json, key);
    if (!p) return -1;
    p = strchr(p, '[');
    if (!p) return -2;
    for (int k = 0; k < 3; k++) {
        char *end;
        out[k] = strtof(p + 1, &end);
        if (end == p + 1) return -3;
        p = end;
        if (*p == ',') p++;
    }
    return 0;
}

static int json_int(const char *json, const char *key)
{
    const char *p = strstr(json, key);
    if (!p) return -1;
    p = strchr(p, ':');
    return p ? atoi(p + 1) : -2;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        printf("用法: %s <head_weights.bin> <test_vectors_dir>\n", argv[0]);
        return 2;
    }
    const char *wpath = argv[1], *tvdir = argv[2];

    printf("== 1. 尺寸断言 ==\n");
    _Static_assert(FC1_IN == FEAT_C, "fc1 输入必须等于特征通道数");
    _Static_assert(FC1_OUT == 256 && FC2_OUT == 3, "fc 维度");
    printf("    feat [1,%d,%d,%d] = %d 元素, w1 [%d,%d], w2 [%d,%d]\n",
           FEAT_C, FEAT_H, FEAT_W, N_FEAT, FC1_OUT, FC1_IN, FC2_OUT, FC1_OUT);
    if (N_FEAT != 46080) fail("特征元素数 %d != 46080", N_FEAT);
    else printf("    46080 元素 ✓\n");

    printf("== 2. 权重加载 ==\n");
    int rc = mfl_head_load(wpath);
    if (rc != 0) {
        printf("    加载失败 rc=%d\n", rc);
        return 1;
    }
    printf("    %s 加载成功 (CRC 校验通过)\n", wpath);

    {
        FILE *f = fopen(wpath, "rb");
        static unsigned char buf[64 * 1024];
        size_t n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        buf[n / 2] ^= 0xFF;
        int bad = mfl_head_load_mem(buf, (int)n);
        if (bad != -3) fail("篡改载荷后应返回 -3(CRC), 实际 %d", bad);
        else printf("    损坏检测 ✓ (CRC 拒绝)\n");
        rc = mfl_head_load(wpath);
        if (rc != 0) { printf("    重载失败\n"); return 1; }
    }

    printf("== 3. GAP 解析解自检 ==\n");
    {
        static int8_t feat[N_FEAT];
        memset(feat, 127, sizeof(feat));
        float gap[FEAT_C];
        mfl_head_gap(feat, gap);
        float expect = 127.0f * FEAT_SCALE;
        float worst = 0.0f;
        for (int c = 0; c < FEAT_C; c++)
            worst = fmaxf(worst, fabsf(gap[c] - expect));
        if (worst > TOL_GAP) fail("常量 127 GAP 误差 %.3e (期望 %.6f)", worst, expect);
        else printf("    常量输入 GAP=%.6f ✓ (误差 %.2e)\n", expect, worst);

        memset(feat, -128, sizeof(feat));
        mfl_head_gap(feat, gap);
        expect = -128.0f * FEAT_SCALE;
        worst = 0.0f;
        for (int c = 0; c < FEAT_C; c++)
            worst = fmaxf(worst, fabsf(gap[c] - expect));
        if (worst > TOL_GAP) fail("常量 -128 GAP 误差 %.3e (期望 %.6f)", worst, expect);
        else printf("    常量 -128 GAP=%.6f ✓ (误差 %.2e)\n", expect, worst);
    }

    printf("== 4/5. 向量对拍 (%s) ==\n", tvdir);
    {
        char path[512], manifest[256 * 1024];
        snprintf(path, sizeof(path), "%s/manifest_head.json", tvdir);
        FILE *mf = fopen(path, "rb");
        if (!mf) { printf("    缺少 manifest: %s\n", path); return 1; }
        size_t mn = fread(manifest, 1, sizeof(manifest) - 1, mf);
        manifest[mn] = 0;
        fclose(mf);

        static int8_t feat[N_FEAT];
        int n_cases = 0, n_argmax_ok = 0, n_logits_ok = 0;
        float worst_dlog = 0.0f, worst_gap = 0.0f, worst_fc1 = 0.0f;

        const char *p = manifest;
        while ((p = strstr(p, "\"name\":")) != NULL) {
            char name[64];
            if (sscanf(p + 7, " \"%63[^\"]\"", name) != 1) break;

            snprintf(path, sizeof(path), "%s/%s_feat_int8.bin", tvdir, name);
            if (read_bin(path, feat, N_FEAT) != 0) { fail("%s 特征向量读取", name); p++; continue; }

            mfl_head_result_t r;
            mfl_head_run(feat, &r);

            static float gap_ref[FEAT_C], fc1_ref[FC1_OUT];
            float gap_cur[FEAT_C], fc1_cur[FC1_OUT];
            snprintf(path, sizeof(path), "%s/%s_gap_f32.bin", tvdir, name);
            read_bin(path, gap_ref, sizeof(gap_ref));
            snprintf(path, sizeof(path), "%s/%s_fc1_f32.bin", tvdir, name);
            read_bin(path, fc1_ref, sizeof(fc1_ref));
            mfl_head_gap(feat, gap_cur);
            mfl_head_fc1(feat, fc1_cur);

            static int8_t feat30[FEAT_C * 30 * 64], pooled[FEAT_C * FEAT_H * FEAT_W];
            snprintf(path, sizeof(path), "%s/%s_feat30_int8.bin", tvdir, name);
            if (read_bin(path, feat30, sizeof(feat30)) == 0) {
                mfl_head_pool2_int8(feat30, pooled);
                if (memcmp(pooled, feat, N_FEAT) != 0)
                    fail("%s 30x64 池化结果与 15x32 向量不一致", name);
            }

            float dgap = 0.0f, dfc1 = 0.0f;
            for (int i = 0; i < FEAT_C; i++)
                dgap = fmaxf(dgap, fabsf(gap_cur[i] - gap_ref[i]));
            for (int j = 0; j < FC1_OUT; j++)
                dfc1 = fmaxf(dfc1, fabsf(fc1_cur[j] - fc1_ref[j]));
            worst_gap = fmaxf(worst_gap, dgap);
            worst_fc1 = fmaxf(worst_fc1, dfc1);

            const char *case_json = p;
            float lg_ref[3], lg_i8[3];
            int am_ref, am_i8;
            if (json_vec3(case_json, "\"logits_f32\":", lg_ref) != 0 ||
                json_vec3(case_json, "\"logits_int8\":", lg_i8) != 0) {
                fail("%s 解析 manifest logits", name); p++; continue;
            }
            am_ref = json_int(case_json, "\"argmax_f32\":");
            am_i8  = json_int(case_json, "\"argmax_int8\":");
            (void)am_ref; (void)am_i8;

            float dlog = 0.0f, di8 = 0.0f;
            for (int k = 0; k < 3; k++) {
                dlog = fmaxf(dlog, fabsf(r.logits[k] - lg_ref[k]));
                di8  = fmaxf(di8,  fabsf(r.logits[k] - lg_i8[k]));
            }

#if MFL_HEAD_QDQ
            const float dacc = di8;
            const float tol = 1e-3f;
            const char *ref_tag = "int8";
            const int   am_exp = am_i8;
#else
            const float dacc = dlog;
            const float tol = TOL_LOGITS;
            const char *ref_tag = "f32 ";
            const int   am_exp = am_ref;
#endif
            worst_dlog = fmaxf(worst_dlog, dacc);

            float psum = r.probs[0] + r.probs[1] + r.probs[2];
            if (fabsf(psum - 1.0f) > 1e-5f) fail("%s softmax 和=%.7f", name, psum);

            int ok_logits = (dacc <= tol);
            int ok_am = (r.pred == am_exp);
            if (ok_logits) n_logits_ok++;
            if (ok_am) n_argmax_ok++;

            printf("    %-8s ref=%s dacc=%.4f/%.3f  (dlog_f32=%.4f dlog_int8=%.4f)  "
                   "dgap=%.2e pred=%d(ref %d)%s%s\n",
                   name, ref_tag, dacc, tol, dlog, di8, dgap, r.pred, am_exp,
                   ok_am ? "" : " ARGMAX-MISMATCH", ok_logits ? "" : " LOGITS-EXCEED");
            if (!ok_logits) fail("%s logits 误差 %.4f > %.4f", name, dacc, tol);
            if (!ok_am) fail("%s argmax %d != ref %d", name, r.pred, am_exp);
            n_cases++;
            p++;
        }

        printf("    案例数 %d;  logits 合格 %d/%d;  argmax 一致 %d/%d\n",
               n_cases, n_logits_ok, n_cases, n_argmax_ok, n_cases);
        printf("    最差: dlogits=%.4f, dGAP=%.2e, dfc1=%.2e\n",
               worst_dlog, worst_gap, worst_fc1);
        if (n_cases == 0) fail("未找到任何测试案例");
        if (n_logits_ok != n_cases || n_argmax_ok != n_cases) fail("对拍未全部通过");
    }

    printf("== 6. 性能基准 ==\n");
    {
        static int8_t feat[N_FEAT];
        for (int i = 0; i < N_FEAT; i++) feat[i] = (int8_t)((i * 37) & 0x3F);
        mfl_head_result_t r;
        for (int i = 0; i < 100; i++) mfl_head_run(feat, &r);
        const int N = 2000;
        double t0 = now_ms();
        for (int i = 0; i < N; i++) mfl_head_run(feat, &r);
        double dt = (now_ms() - t0) / N;
        printf("    %.3f ms/次 (%d 次平均)\n", dt, N);
        if (dt > 5.0) printf("    注意: PC 上偏慢, 板端 A53 预计 <1ms\n");
    }

    printf("\n%s (失败项 %d)\n", g_fail ? "FAILED" : "ALL PASS", g_fail);
    return g_fail ? 1 : 0;
}
