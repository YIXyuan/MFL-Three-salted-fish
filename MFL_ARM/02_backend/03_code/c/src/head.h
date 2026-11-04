#ifndef MFL_HEAD_H
#define MFL_HEAD_H

#include <stdint.h>

typedef struct {
    float logits[3];
    float probs[3];
    int   pred;
    float conf;
} mfl_head_result_t;

int  mfl_head_load(const char *path);

int  mfl_head_load_mem(const void *packed                            , int bytes);

void mfl_head_run(const int8_t *feat, mfl_head_result_t *out);

void mfl_head_pool2_int8(const int8_t *in30, int8_t *out15);

void mfl_head_gap(const int8_t *feat, float gap_out[96]);

void mfl_head_fc1(const int8_t *feat, float fc1_out[256]);

#endif
