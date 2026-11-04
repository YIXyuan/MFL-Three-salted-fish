#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../preprocess.h"

static int n_fail = 0;

#define CHECK(cond, name) do { \
    if (cond) printf("  [PASS] %s\n", name); \
    else { printf("  [FAIL] %s\n", name); n_fail++; } } while (0)

int main(int argc, char **argv)
{

    {
        const int W = MFL_IMG_W, H = MFL_IMG_H;
        uint8_t *hwc = malloc((size_t)W * H * 3);
        int8_t  *out = malloc(MFL_IN_TENSOR_BYTES);
        int8_t  *ref = malloc(MFL_IN_TENSOR_BYTES);
        srand(42);
        for (size_t i = 0; i < (size_t)W * H * 3; i++) hwc[i] = (uint8_t)(rand() & 0xFF);

        mfl_quantize_chw(hwc, W, H, out);

        for (int c = 0; c < 3; c++)
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    uint8_t v = hwc[((size_t)y * W + x) * 3 + c];
                    ref[(size_t)c * H * W + (size_t)y * W + x] = (int8_t)(v >> 1);
                }

        CHECK(memcmp(out, ref, MFL_IN_TENSOR_BYTES) == 0, "quantize_chw == naive reference (CHW + >>1)");
        free(hwc); free(out); free(ref);
    }

    {
        long bad = 0;
        for (int v = 0; v <= 255; v++) {
            int q_f32 = (int)lrintf((float)v / 255.0f * 127.0f);
            int q_shr = v >> 1;
            if (q_f32 != q_shr) bad++;
        }
        CHECK(bad == 0, "round(v/255*127) == (v>>1) for all v in 0..255");
    }

    {
        const int W = MFL_IMG_W, H = MFL_IMG_H;
        uint8_t *hwc = malloc((size_t)W * H * 3);
        int8_t  *outA = malloc(MFL_IN_TENSOR_BYTES);
        int8_t  *outB = malloc(MFL_IN_TENSOR_BYTES);
        srand(7);
        for (size_t i = 0; i < (size_t)W * H * 3; i++) hwc[i] = (uint8_t)(rand() & 0xFF);
        mfl_quantize_chw(hwc, W, H, outA);
        mfl_quantize_chw_scaled(hwc, W, H, outB, 127.0f / 255.0f);
        CHECK(memcmp(outA, outB, MFL_IN_TENSOR_BYTES) == 0,
              "scaled kernel (k=127/255) == kernel A (>>1)");
        free(hwc); free(outA); free(outB);
    }

    {
        struct { uint16_t h; float want; } cases[] = {
            {0x0000, 0.0f},      {0x3C00, 1.0f},       {0xBC00, -1.0f},
            {0x3800, 0.5f},      {0x4000, 2.0f},       {0x0001, 5.9604645e-08f},
            {0x3555, 0.33325195f},
        };
        long bad = 0;
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
            if (mfl_fp16_to_fp32(cases[i].h) != cases[i].want) bad++;
        CHECK(bad == 0, "fp16->fp32 known values (normal/subnormal/negative)");
    }

    {
        const long N = MFL_IN_TENSOR_BYTES;
        float *vec = malloc((size_t)N * sizeof(float));
        FILE *f = fopen("/tmp/mfl_eq_test.bin", "wb");
        for (long i = 0; i < N; i++) {
            int v = (int)(i & 0xFF);
            vec[i] = (float)v / 255.0f;
        }
        fwrite(vec, sizeof(float), (size_t)N, f);
        fclose(f);
        long nd = 0;
        CHECK(mfl_check_equivalence("/tmp/mfl_eq_test.bin", 1.0f / 127.0f,
                                    &nd, NULL) == MFL_OK && nd == 0,
              "equivalence PASS at scale=1/127");
        CHECK(mfl_check_equivalence("/tmp/mfl_eq_test.bin", 0.007f,
                                    NULL, NULL) == MFL_ERR_MISMATCH,
              "equivalence FAIL at scale=0.007 (scale-sensitive)");
        free(vec);
        remove("/tmp/mfl_eq_test.bin");
    }

    if (argc >= 2) {
        static int8_t tensor[MFL_IN_TENSOR_BYTES];
        memset(tensor, 0x5A, sizeof(tensor));
        int rc = mfl_preprocess_file(argv[1], tensor);
        CHECK(rc == MFL_ERR_SIZE, "size-mismatch file returns MFL_ERR_SIZE");
        CHECK(g_mfl_pre_stats.n_skip_size == 1, "size-skip counter incremented");
    }

    {
        static int8_t tensor[MFL_IN_TENSOR_BYTES];
        int rc = mfl_preprocess_file("tests/data/not_an_image.bin", tensor);
        CHECK(rc == MFL_ERR_DECODE, "non-image file returns MFL_ERR_DECODE");
        CHECK(g_mfl_pre_stats.n_skip_decode == 1, "decode-fail counter incremented");
    }

    CHECK(mfl_preprocess_file(NULL, NULL) == MFL_ERR_ARGS, "NULL args rejected");

    printf(n_fail ? "RESULT: %d FAILURE(S)\n" : "RESULT: ALL PASS\n", n_fail);
    return n_fail ? 1 : 0;
}
