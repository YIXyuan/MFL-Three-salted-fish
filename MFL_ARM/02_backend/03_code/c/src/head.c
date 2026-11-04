#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "head.h"
#include "quant_params.h"

#ifndef MFL_HEAD_QDQ
#define MFL_HEAD_QDQ 0
#endif

#define N_TAPS   (FEAT_H * FEAT_W)

static int8_t  w1[FC1_OUT][FC1_IN];
static int32_t b1v[FC1_OUT];
static int8_t  w2[FC2_OUT][FC1_OUT];
static int32_t b2v[FC2_OUT];
static int     g_loaded = 0;

#pragma pack(push, 1)
typedef struct {
    char     magic[4];
    uint32_t version;
    uint32_t crc32;
    uint32_t bytes[4];
} head_file_hdr_t;
#pragma pack(pop)

static uint32_t crc32_calc(const uint8_t *p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1)));
    }
    return ~c;
}

#if MFL_HEAD_QDQ
static int8_t sat8(int v)
{
    if (v > 127)  return 127;
    if (v < -128) return -128;
    return (int8_t)v;
}
#endif

int mfl_head_load_mem(const void *packed, int bytes)
{
    const head_file_hdr_t *h = (const head_file_hdr_t *)packed;
    size_t need = sizeof(*h)
        + (size_t)FC1_OUT * FC1_IN + (size_t)FC1_OUT * 4
        + (size_t)FC2_OUT * FC1_OUT + (size_t)FC2_OUT * 4;
    if (!packed || bytes < (int)need)                    return -4;
    if (memcmp(h->magic, "MFLH", 4) != 0 || h->version != 1) return -2;
    if (h->bytes[0] != FC1_OUT * FC1_IN || h->bytes[1] != FC1_OUT * 4 ||
        h->bytes[2] != FC2_OUT * FC1_OUT || h->bytes[3] != FC2_OUT * 4)
        return -4;
    const uint8_t *p = (const uint8_t *)packed + sizeof(*h);
    if (crc32_calc(p, need - sizeof(*h)) != h->crc32)    return -3;

    memcpy(w1,  p, h->bytes[0]); p += h->bytes[0];
    memcpy(b1v, p, h->bytes[1]); p += h->bytes[1];
    memcpy(w2,  p, h->bytes[2]); p += h->bytes[2];
    memcpy(b2v, p, h->bytes[3]);
    g_loaded = 1;
    return 0;
}

int mfl_head_load(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    unsigned char buf[64 * 1024];
    size_t n = fread(buf, 1, sizeof(buf), f);
    int extra = fgetc(f);
    fclose(f);
    if (n == 0 || extra != EOF) return -4;
    return mfl_head_load_mem(buf, (int)n);
}

void mfl_head_gap(const int8_t *feat, float gap_out[96])
{
    for (int c = 0; c < FEAT_C; c++) {
        int32_t acc = 0;
        const int8_t *p = feat + (size_t)c * N_TAPS;
        for (int i = 0; i < N_TAPS; i++)
            acc += p[i];
        gap_out[c] = (float)acc * FEAT_SCALE / (float)N_TAPS;
    }
}

void mfl_head_fc1(const int8_t *feat, float fc1_out[256])
{
    float gap[FEAT_C];
    mfl_head_gap(feat, gap);

#if MFL_HEAD_QDQ

    int8_t q1[FEAT_C];
    for (int c = 0; c < FEAT_C; c++)
        q1[c] = sat8(lrintf(gap[c] / FC1_IN_SCALE));
#endif

    for (int j = 0; j < FC1_OUT; j++) {
#if MFL_HEAD_QDQ
        int32_t a = b1v[j];
        const int8_t *wr = w1[j];
        for (int i = 0; i < FEAT_C; i++)
            a += (int32_t)q1[i] * wr[i];

        float y = (float)a * (FC1_IN_SCALE * fc1_w_scale[j]);
        fc1_out[j] = lrintf(y / FC1_OUT_SCALE) * FC1_OUT_SCALE;
#else
        float s = (float)b1v[j] * fc1_b_scale[j];
        const int8_t *wr = w1[j];
        const float ws = fc1_w_scale[j];
        for (int i = 0; i < FEAT_C; i++)
            s += gap[i] * ((float)wr[i] * ws);
        fc1_out[j] = s;
#endif
    }
}

void mfl_head_pool2_int8(const int8_t *in30, int8_t *out15)
{
    for (int c = 0; c < FEAT_C; c++) {
        const int8_t *src = in30 + (size_t)c * 30 * 64;
        int8_t *dst = out15 + (size_t)c * FEAT_H * FEAT_W;
        for (int y = 0; y < FEAT_H; y++) {
            for (int x = 0; x < FEAT_W; x++) {
                int8_t a = src[(2 * y) * 64 + 2 * x];
                int8_t b = src[(2 * y) * 64 + 2 * x + 1];
                int8_t c2 = src[(2 * y + 1) * 64 + 2 * x];
                int8_t d = src[(2 * y + 1) * 64 + 2 * x + 1];
                int8_t m = a;
                if (b > m) m = b;
                if (c2 > m) m = c2;
                if (d > m) m = d;

                dst[y * FEAT_W + x] = m < 0 ? 0 : m;
            }
        }
    }
}

void mfl_head_run(const int8_t *feat, mfl_head_result_t *out)
{
    if (!g_loaded) {

        for (int k = 0; k < 3; k++) { out->logits[k] = NAN; out->probs[k] = NAN; }
        out->pred = -1; out->conf = NAN;
        return;
    }

    float y1[FC1_OUT];
    mfl_head_fc1(feat, y1);
    for (int j = 0; j < FC1_OUT; j++)
        y1[j] = y1[j] > 0.0f ? y1[j] : 0.0f;

    float lg[FC2_OUT];
#if MFL_HEAD_QDQ
    int8_t q2[FC1_OUT];
    for (int j = 0; j < FC1_OUT; j++)
        q2[j] = sat8(lrintf(y1[j] / RELU_SCALE));
    for (int k = 0; k < FC2_OUT; k++) {
        int32_t a = b2v[k];
        const int8_t *wr = w2[k];
        for (int j = 0; j < FC1_OUT; j++)
            a += (int32_t)q2[j] * wr[j];

        float y = (float)a * (RELU_SCALE * fc2_w_scale[k]);
        lg[k] = lrintf(y / LOGITS_SCALE) * LOGITS_SCALE;
    }
#else
    for (int k = 0; k < FC2_OUT; k++) {
        float s = (float)b2v[k] * fc2_b_scale[k];
        const int8_t *wr = w2[k];
        const float ws = fc2_w_scale[k];
        for (int j = 0; j < FC1_OUT; j++)
            s += y1[j] * ((float)wr[j] * ws);
        lg[k] = s;
    }
#endif

    for (int k = 0; k < FC2_OUT; k++)
        out->logits[k] = lg[k];

    float m = lg[0];
    for (int k = 1; k < FC2_OUT; k++)
        if (lg[k] > m) m = lg[k];
    float z = 0.0f;
    for (int k = 0; k < FC2_OUT; k++) {
        out->probs[k] = expf(lg[k] - m);
        z += out->probs[k];
    }
    for (int k = 0; k < FC2_OUT; k++)
        out->probs[k] /= z;

    out->pred = 0;
    for (int k = 1; k < FC2_OUT; k++)
        if (lg[k] > lg[out->pred]) out->pred = k;
    out->conf = out->probs[out->pred];
}
