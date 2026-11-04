#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "head.h"
#include "head_params.h"

const char *const mfl_head_class_names[MFL_HEAD_CLASSES] = {
    "normal", "light_corrosion", "severe_corrosion"
};

int mfl_head_load(const char *bin_path, MflHeadWeights *w, void **owner)
{
    if (!bin_path || !w || !owner) return -1;
    *owner = NULL;

    FILE *f = fopen(bin_path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long len = ftell(f);
    if (len != MFL_HEAD_BIN_SIZE) { fclose(f); return -2; }
    rewind(f);

    unsigned char *buf = malloc(MFL_HEAD_BIN_SIZE);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, MFL_HEAD_BIN_SIZE, f) != MFL_HEAD_BIN_SIZE) {
        free(buf);
        fclose(f);
        return -1;
    }
    fclose(f);

    w->fc1_w  = (const int8_t  *)(buf + MFL_HEAD_FC1_W_OFF);
    w->fc1_bq = (const int32_t *)(buf + MFL_HEAD_FC1_B_OFF);
    w->fc2_w  = (const int8_t  *)(buf + MFL_HEAD_FC2_W_OFF);
    w->fc2_bq = (const int32_t *)(buf + MFL_HEAD_FC2_B_OFF);
    *owner = buf;
    return 0;
}

void mfl_head_release(void *owner)
{
    free(owner);
}

void mfl_relu_pool5(const int8_t *conv09_out, int8_t *feat)
{

    enum { IN_H = 2 * MFL_HEAD_FEAT_H, IN_W = 2 * MFL_HEAD_FEAT_W };

    for (int c = 0; c < MFL_HEAD_FEAT_CH; c++) {
        const int8_t *in = conv09_out + (size_t)c * IN_H * IN_W;
        int8_t *out = feat + (size_t)c * MFL_HEAD_FEAT_H * MFL_HEAD_FEAT_W;
        for (int y = 0; y < MFL_HEAD_FEAT_H; y++) {
            const int8_t *r0 = in + (size_t)(2 * y) * IN_W;
            const int8_t *r1 = in + (size_t)(2 * y + 1) * IN_W;
            for (int x = 0; x < MFL_HEAD_FEAT_W; x++) {
                int m = r0[2 * x];
                if (r0[2 * x + 1] > m) m = r0[2 * x + 1];
                if (r1[2 * x]     > m) m = r1[2 * x];
                if (r1[2 * x + 1] > m) m = r1[2 * x + 1];
                out[(size_t)y * MFL_HEAD_FEAT_W + x] = (int8_t)(m < 0 ? 0 : m);
            }
        }
    }
}

static inline int mfl_clamp_i8(int q)
{
    if (q > 127)  return 127;
    if (q < -128) return -128;
    return q;
}

int mfl_head_forward(const MflHeadWeights *w, const int8_t *feat,
                     float *logits, float *probs)
{
    if (!w || !feat || !logits) return -1;

    int32_t q1[MFL_HEAD_FEAT_CH];
    const int GAP_N = MFL_HEAD_FEAT_H * MFL_HEAD_FEAT_W;
    for (int c = 0; c < MFL_HEAD_FEAT_CH; c++) {
        const int8_t *p = feat + (size_t)c * GAP_N;
        int32_t sum = 0;
        for (int i = 0; i < GAP_N; i++)
            sum += p[i];
        q1[c] = mfl_clamp_i8(lrintf((float)sum * MFL_GAP_K));
    }

    int8_t q2[MFL_HEAD_FC1_OUT];
    for (int c = 0; c < MFL_HEAD_FC1_OUT; c++) {
        const int8_t *wc = w->fc1_w + (size_t)c * MFL_HEAD_FEAT_CH;
        int32_t acc = w->fc1_bq[c];
        for (int k = 0; k < MFL_HEAD_FEAT_CH; k++)
            acc += (int32_t)q1[k] * (int32_t)wc[k];
        float y = (float)acc * (MFL_S_FC1_IN * mfl_fc1_w_scale[c]);
        int q = mfl_clamp_i8(lrintf(y / MFL_S_FC1_OUT));
        if (q < 0) q = 0;

        q = mfl_clamp_i8(lrintf((float)q * MFL_RELU_REQ_K));
        q2[c] = (int8_t)q;
    }

    float lg[MFL_HEAD_CLASSES];
    for (int c = 0; c < MFL_HEAD_CLASSES; c++) {
        const int8_t *wc = w->fc2_w + (size_t)c * MFL_HEAD_FC1_OUT;
        int32_t acc = w->fc2_bq[c];
        for (int k = 0; k < MFL_HEAD_FC1_OUT; k++)
            acc += (int32_t)q2[k] * (int32_t)wc[k];
        float y = (float)acc * (MFL_S_FC2_IN * mfl_fc2_w_scale[c]);
        int q = mfl_clamp_i8(lrintf(y / MFL_S_FC2_OUT));
        lg[c] = (float)q * MFL_S_FC2_OUT;
    }

    for (int c = 0; c < MFL_HEAD_CLASSES; c++)
        logits[c] = lg[c];

    if (probs) {
        float mx = lg[0];
        for (int c = 1; c < MFL_HEAD_CLASSES; c++)
            if (lg[c] > mx) mx = lg[c];
        float s = 0.0f;
        for (int c = 0; c < MFL_HEAD_CLASSES; c++) {
            probs[c] = expf(lg[c] - mx);
            s += probs[c];
        }
        for (int c = 0; c < MFL_HEAD_CLASSES; c++)
            probs[c] /= s;
    }

    int am = MFL_HEAD_CLASSES - 1;
    for (int c = MFL_HEAD_CLASSES - 2; c >= 0; c--)
        if (lg[c] > lg[am]) am = c;
    return am;
}

#ifdef MFL_HEAD_STANDALONE
static int run_head(const char *feat_path, int from_conv09,
                    const char *w_path, const char *expect)
{
    void *owner = NULL;
    MflHeadWeights w;
    if (mfl_head_load(w_path, &w, &owner) != 0) {
        fprintf(stderr, "[head] load weights failed: %s\n", w_path);
        return 1;
    }

    size_t need = from_conv09 ? (size_t)MFL_HEAD_FEAT_CH * 2 * MFL_HEAD_FEAT_H
                              * 2 * MFL_HEAD_FEAT_W
                              : MFL_HEAD_FEAT_ELEMS;
    int8_t *raw = malloc(need);
    int8_t *feat = malloc(MFL_HEAD_FEAT_ELEMS);
    if (!raw || !feat) { perror("OOM"); return 1; }

    FILE *f = fopen(feat_path, "rb");
    if (!f || fread(raw, 1, need, f) != need) {
        fprintf(stderr, "[head] read feat failed: %s (need %zu bytes)\n",
                feat_path, need);
        return 1;
    }
    fclose(f);

    if (from_conv09)
        mfl_relu_pool5(raw, feat);
    else
        memcpy(feat, raw, MFL_HEAD_FEAT_ELEMS);

    float logits[3], probs[3];
    int cls = mfl_head_forward(&w, feat, logits, probs);

    printf("logits  : %.6f %.6f %.6f\n", logits[0], logits[1], logits[2]);
    printf("softmax : %.6f %.6f %.6f\n", probs[0], probs[1], probs[2]);
    printf("predict : class %d (%s)\n", cls, mfl_head_class_names[cls]);

    if (expect) {
        float e[3];
        if (sscanf(expect, "%f %f %f", &e[0], &e[1], &e[2]) == 3) {
            float md = 0.0f;
            for (int i = 0; i < 3; i++) {
                float d = fabsf(logits[i] - e[i]);
                if (d > md) md = d;
                printf("  |logit[%d] - ref| = %.4f\n", i, d);
            }
            printf("max|d| = %.4f %s\n", md,
                   md < 0.1f ? "(<0.1 PASS)" : "(>=0.1 check口径)");
        }
    }

    free(raw);
    free(feat);
    mfl_head_release(owner);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 4 && strcmp(argv[1], "--from-conv09") == 0)
        return run_head(argv[2], 1, argv[3], argc >= 5 ? argv[4] : NULL);
    if (argc >= 3)
        return run_head(argv[1], 0, argv[2], argc >= 4 ? argv[3] : NULL);

    fprintf(stderr,
        "usage:\n"
        "  %s <feat_int8.bin> <mfl_head.bin> [\"ref l0 l1 l2\"]\n"
        "  %s --from-conv09 <conv09_out_int8.bin> <mfl_head.bin> [\"ref l0 l1 l2\"]\n"
        "  feat: 96x15x32 int8 NCHW (scale=%.9g)  |  conv09: 96x30x64 pre-relu int8\n"
        "  ref 可选: manifest.json 的 logits_f32, 逐项打印误差\n",
        argv[0], argv[0], (double)MFL_S_FEAT);
    return 1;
}
#endif
