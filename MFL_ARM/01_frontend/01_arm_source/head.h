#ifndef MFL_HEAD_H
#define MFL_HEAD_H

#include <stdint.h>
#include <stddef.h>

#define MFL_HEAD_FEAT_CH   96
#define MFL_HEAD_FEAT_H    15
#define MFL_HEAD_FEAT_W    32
#define MFL_HEAD_FEAT_ELEMS (MFL_HEAD_FEAT_CH * MFL_HEAD_FEAT_H * MFL_HEAD_FEAT_W)
#define MFL_HEAD_FC1_OUT   256
#define MFL_HEAD_CLASSES   3

extern const char *const mfl_head_class_names[MFL_HEAD_CLASSES];

typedef struct {
    const int8_t  *fc1_w;
    const int32_t *fc1_bq;
    const int8_t  *fc2_w;
    const int32_t *fc2_bq;
} MflHeadWeights;

int  mfl_head_load(const char *bin_path, MflHeadWeights *w, void **owner);
void mfl_head_release(void *owner);

int mfl_head_forward(const MflHeadWeights *w, const int8_t *feat,
                     float *logits, float *probs);

void mfl_relu_pool5(const int8_t *conv09_out, int8_t *feat);

#endif
