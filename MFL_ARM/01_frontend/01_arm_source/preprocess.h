#ifndef MFL_PREPROCESS_H
#define MFL_PREPROCESS_H

#include <stdint.h>
#include <stddef.h>

#define MFL_IMG_W          1024
#define MFL_IMG_H          480
#define MFL_IMG_C          3
#define MFL_IN_TENSOR_BYTES (MFL_IMG_C * MFL_IMG_H * MFL_IMG_W)

enum {
    MFL_OK           =  0,
    MFL_ERR_DECODE   = -1,
    MFL_ERR_SIZE     = -2,
    MFL_ERR_IO       = -3,
    MFL_ERR_ARGS     = -4,
    MFL_ERR_MISMATCH = -5
};

extern int mfl_log_level;

typedef struct {
    long n_ok;
    long n_skip_size;
    long n_skip_decode;
} mfl_pre_stats;

extern mfl_pre_stats g_mfl_pre_stats;

int mfl_preprocess_file(const char *path, int8_t *out_tensor);

void mfl_quantize_chw(const uint8_t *hwc, int w, int h, int8_t *chw);

void mfl_quantize_chw_scaled(const uint8_t *hwc, int w, int h, int8_t *chw, float k);

float mfl_fp16_to_fp32(uint16_t h);

int mfl_selftest_preprocess(const char *jpg_path, const char *int8_bin_path,
                            int tol, long *out_n_diff, int *out_max_abs);

int mfl_check_equivalence(const char *vec_path, float input_scale,
                          long *out_n_diff, float *out_max_abs);

#endif
