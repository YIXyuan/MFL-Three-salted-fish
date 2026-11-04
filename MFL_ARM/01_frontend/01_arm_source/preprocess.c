#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

#include "preprocess.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

int mfl_log_level = 1;
mfl_pre_stats g_mfl_pre_stats = {0, 0, 0};

static void mfl_log(int lvl, const char *fmt, ...)
{
    if (mfl_log_level < lvl) return;
    va_list ap;
    va_start(ap, fmt);
    fputs("[preprocess] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

void mfl_quantize_chw(const uint8_t *hwc, int w, int h, int8_t *chw)
{
    for (int c = 0; c < MFL_IMG_C; c++) {
        for (int y = 0; y < h; y++) {
            const uint8_t *src = hwc + (size_t)(y * w) * 3 + c;
            int8_t *dst = chw + (size_t)c * h * w + (size_t)y * w;
            for (int x = 0; x < w; x++)
                dst[x] = (int8_t)(src[x * 3] >> 1);
        }
    }
}

void mfl_quantize_chw_scaled(const uint8_t *hwc, int w, int h, int8_t *chw, float k)
{
    for (int c = 0; c < MFL_IMG_C; c++) {
        for (int y = 0; y < h; y++) {
            const uint8_t *src = hwc + (size_t)(y * w) * 3 + c;
            int8_t *dst = chw + (size_t)c * h * w + (size_t)y * w;
            for (int x = 0; x < w; x++) {
                int q = lrintf((float)src[x * 3] * k);
                if (q > 127)   q = 127;
                if (q < -128)  q = -128;
                dst[x] = (int8_t)q;
            }
        }
    }
}

float mfl_fp16_to_fp32(uint16_t h)
{
    uint32_t sign = (uint32_t)(h & 0x8000u) << 16;
    uint32_t exp  = (h >> 10) & 0x1Fu;
    uint32_t man  = h & 0x03FFu;
    uint32_t bits;

    if (exp == 0) {
        if (man == 0) {
            bits = sign;
        } else {
            int e = -1;
            uint32_t m = man;
            do { m <<= 1; e++; } while (!(m & 0x0400u));
            bits = sign | ((uint32_t)(127 - 15 - e) << 23) | ((m & 0x03FFu) << 13);
        }
    } else if (exp == 0x1Fu) {
        bits = sign | 0x7F800000u | (man << 13);
    } else {
        bits = sign | ((exp - 15 + 127) << 23) | (man << 13);
    }

    float f;
    memcpy(&f, &bits, sizeof f);
    return f;
}

int mfl_preprocess_file(const char *path, int8_t *out_tensor)
{
    int w = 0, h = 0, comp = 0;

    if (!path || !out_tensor) return MFL_ERR_ARGS;

    unsigned char *hwc = stbi_load(path, &w, &h, &comp, MFL_IMG_C);
    if (!hwc) {
        g_mfl_pre_stats.n_skip_decode++;
        mfl_log(1, "decode failed: %s (%s)", path, stbi_failure_reason());
        return MFL_ERR_DECODE;
    }

    if (w != MFL_IMG_W || h != MFL_IMG_H) {
        g_mfl_pre_stats.n_skip_size++;
        mfl_log(1, "size mismatch, skip: %s (%dx%d, expect %dx%d)",
                path, w, h, MFL_IMG_W, MFL_IMG_H);
        stbi_image_free(hwc);
        return MFL_ERR_SIZE;
    }

    mfl_quantize_chw(hwc, w, h, out_tensor);
    stbi_image_free(hwc);

    g_mfl_pre_stats.n_ok++;
    mfl_log(2, "ok: %s", path);
    return MFL_OK;
}

static long read_whole_file(const char *path, void **out_buf)
{
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long len = ftell(f);
    if (len < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    void *buf = malloc(len ? (size_t)len : 1);
    if (!buf) { fclose(f); return -1; }
    if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf); fclose(f); return -1;
    }
    fclose(f);
    *out_buf = buf;
    return len;
}

int mfl_selftest_preprocess(const char *jpg_path, const char *int8_bin_path,
                            int tol, long *out_n_diff, int *out_max_abs)
{
    int8_t *tensor = NULL;
    int8_t *ref = NULL;
    long ref_len;
    long n_diff = 0;
    int max_abs = 0;
    int rc = MFL_OK;

    tensor = malloc(MFL_IN_TENSOR_BYTES);
    if (!tensor) return MFL_ERR_IO;

    rc = mfl_preprocess_file(jpg_path, tensor);
    if (rc != MFL_OK) goto out;

    ref_len = read_whole_file(int8_bin_path, (void **)&ref);
    if (ref_len != MFL_IN_TENSOR_BYTES) {
        mfl_log(0, "selftest: bad ref file '%s' (len=%ld, expect %d)",
                int8_bin_path, ref_len, MFL_IN_TENSOR_BYTES);
        rc = MFL_ERR_IO;
        goto out;
    }

    for (long i = 0; i < MFL_IN_TENSOR_BYTES; i++) {
        int d = (int)tensor[i] - (int)ref[i];
        if (d < 0) d = -d;
        if (d > tol) {
            n_diff++;
            if (d > max_abs) max_abs = d;
        }
    }

    if (out_n_diff)  *out_n_diff  = n_diff;
    if (out_max_abs) *out_max_abs = max_abs;

    if (n_diff == 0) {
        mfl_log(1, "selftest preprocess: PASS (tol=%d, %d bytes)", tol, MFL_IN_TENSOR_BYTES);
    } else {
        mfl_log(0, "selftest preprocess: FAIL (%ld/%d bytes over tol=%d, max|d|=%d)",
                n_diff, MFL_IN_TENSOR_BYTES, tol, max_abs);
        rc = MFL_ERR_MISMATCH;
    }

out:
    free(tensor);
    free(ref);
    return rc;
}

int mfl_check_equivalence(const char *vec_path, float input_scale,
                          long *out_n_diff, float *out_max_abs)
{
    const long N = MFL_IN_TENSOR_BYTES;
    uint16_t *h16 = NULL;
    float    *vec = NULL;
    long len = read_whole_file(vec_path, (void **)&h16);
    int is_fp16 = 0;

    if (len == 2 * N) {
        is_fp16 = 1;
        vec = malloc((size_t)N * sizeof(float));
        if (!vec) { free(h16); return MFL_ERR_IO; }
        for (long i = 0; i < N; i++)
            vec[i] = mfl_fp16_to_fp32(h16[i]);
        free(h16);
    } else if (len == 4 * N) {
        vec = (float *)h16;
    } else {
        mfl_log(0, "equivalence: bad vector file '%s' (%ld bytes; "
                   "expect %ld(fp16) or %ld(fp32) - npy转bin请保留原始dtype)",
                vec_path, len, 2 * N, 4 * N);
        free(h16);
        return MFL_ERR_IO;
    }

    long n_diff = 0;
    float max_abs = 0.0f;

    for (long i = 0; i < N; i++) {
        float f = vec[i];
        int v = (int)lrintf(f * 255.0f);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        int q_pc = (int)lrintf(f / input_scale);
        if (q_pc > 127) q_pc = 127;
        if (q_pc < -128) q_pc = -128;
        int q_board = v >> 1;
        if (q_pc != q_board) {
            n_diff++;
            float d = (float)(q_pc > q_board ? q_pc - q_board : q_board - q_pc);
            if (d > max_abs) max_abs = d;
        }
    }

    if (out_n_diff)  *out_n_diff  = n_diff;
    if (out_max_abs) *out_max_abs = max_abs;

    free(vec);

    if (n_diff == 0) {
        mfl_log(1, "equivalence: PASS (%ld elems, %s, scale=%g)",
                N, is_fp16 ? "fp16" : "fp32", (double)input_scale);
        return MFL_OK;
    }
    mfl_log(0, "equivalence: FAIL (%ld/%ld mismatch, max|d|=%g, %s, scale=%g) "
               "- 若失配呈规律性, 板端应切内核 B(mfl_quantize_chw_scaled)",
            n_diff, N, (double)max_abs, is_fp16 ? "fp16" : "fp32",
            (double)input_scale);
    return MFL_ERR_MISMATCH;
}

#ifdef MFL_PREPROCESS_STANDALONE
int main(int argc, char **argv)
{
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "--equivalence") == 0) {
        float scale = (argc == 4) ? (float)atof(argv[3])
                                  : (1.0f / 127.0f);
        return mfl_check_equivalence(argv[2], scale, NULL, NULL);
    }

    if (argc >= 4 && strcmp(argv[1], "--selftest") == 0) {
        int tol = (argc >= 5) ? atoi(argv[4]) : 0;
        return mfl_selftest_preprocess(argv[2], argv[3], tol, NULL, NULL);
    }

    if (argc == 3) {
        int8_t *tensor = malloc(MFL_IN_TENSOR_BYTES);
        if (!tensor) { fputs("OOM\n", stderr); return 1; }
        int rc = mfl_preprocess_file(argv[1], tensor);
        if (rc != MFL_OK) return rc;
        FILE *f = fopen(argv[2], "wb");
        if (!f || fwrite(tensor, 1, MFL_IN_TENSOR_BYTES, f) != MFL_IN_TENSOR_BYTES) {
            perror("write"); return 1;
        }
        fclose(f);
        fprintf(stderr, "[preprocess] wrote %s (%d bytes)\n", argv[2], MFL_IN_TENSOR_BYTES);
        free(tensor);
        return 0;
    }

    fprintf(stderr,
        "usage:\n"
        "  %s <img.jpg> <out.bin>                     preprocess + dump tensor\n"
        "  %s --selftest <img.jpg> <input_int8.bin> [tol]\n"
        "  %s --equivalence <input_f32.bin> [scale]   scale 取 quant_params.json 的\n"
        "                                             input.scale, 缺省 1/127\n",
        argv[0], argv[0], argv[0]);
    return MFL_ERR_ARGS;
}
#endif
