#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "../head.h"
#include "../head_params.h"

static int n_fail = 0;

#define CHECK(cond, name) do { \
    if (cond) printf("  [PASS] %s\n", name); \
    else { printf("  [FAIL] %s\n", name); n_fail++; } } while (0)

int main(void)
{

    MflHeadWeights w;
    void *owner = NULL;
    int rc = mfl_head_load("weights/mfl_head.bin", &w, &owner);
    CHECK(rc == 0, "mfl_head_load ok");
    if (rc != 0) { printf("RESULT: ABORT\n"); return 2; }
    CHECK((const unsigned char *)w.fc1_bq - (const unsigned char *)w.fc1_w
              == MFL_HEAD_FC1_B_OFF, "fc1_bq offset == 24576");
    CHECK((const unsigned char *)w.fc2_w - (const unsigned char *)w.fc1_w
              == MFL_HEAD_FC2_W_OFF, "fc2_w offset == 25600");
    CHECK((const unsigned char *)w.fc2_bq - (const unsigned char *)w.fc1_w
              == MFL_HEAD_FC2_B_OFF, "fc2_bq offset == 26368");
    CHECK(mfl_head_load("weights/mfl_head.bin", NULL, NULL) == -1, "NULL args rejected");
    CHECK(mfl_head_load("tests/data/not_an_image.bin", &w, NULL) != 0,
          "wrong-size file rejected (need MFL_HEAD_BIN_SIZE)");

    {
        enum { IN_H = 2 * MFL_HEAD_FEAT_H, IN_W = 2 * MFL_HEAD_FEAT_W };
        int8_t *c9 = malloc((size_t)MFL_HEAD_FEAT_CH * IN_H * IN_W);
        int8_t *feat = malloc(MFL_HEAD_FEAT_ELEMS);
        memset(c9, -3, (size_t)MFL_HEAD_FEAT_CH * IN_H * IN_W);

        c9[0] = -1; c9[1] = 3; c9[IN_W] = -7; c9[IN_W + 1] = 2;

        c9[(3 * IN_W + 5) * 2 / 2 * 1 + 0] = c9[3 * 2 * IN_W + 2 * 5] = -9;
        c9[3 * 2 * IN_W + 2 * 5 + 1] = -8;
        c9[(3 * 2 + 1) * IN_W + 2 * 5] = -2;
        c9[(3 * 2 + 1) * IN_W + 2 * 5 + 1] = -6;

        size_t base5 = (size_t)5 * IN_H * IN_W;
        c9[base5 + 7 * 2 * IN_W + 2 * 31] = 127;
        c9[base5 + 7 * 2 * IN_W + 2 * 31 + 1] = -1;
        c9[base5 + (7 * 2 + 1) * IN_W + 2 * 31] = -128;
        c9[base5 + (7 * 2 + 1) * IN_W + 2 * 31 + 1] = 126;

        mfl_relu_pool5(c9, feat);

        int ok = feat[0] == 3;
        CHECK(ok, "relu_pool5 window0 {-1,3,-7,2} -> 3");
        ok = feat[3 * MFL_HEAD_FEAT_W + 5] == 0;
        CHECK(ok, "relu_pool5 all-negative window -> 0");
        ok = feat[(size_t)5 * MFL_HEAD_FEAT_H * MFL_HEAD_FEAT_W + 7 * MFL_HEAD_FEAT_W + 31] == 127;
        CHECK(ok, "relu_pool5 boundary window {127,-1,-128,126} -> 127");
        free(c9);
        free(feat);
    }

    {
        int8_t *feat = malloc(MFL_HEAD_FEAT_ELEMS);
        FILE *f = fopen("tests/data/head_synth_feat.bin", "rb");
        int ok = f && fread(feat, 1, MFL_HEAD_FEAT_ELEMS, f) == MFL_HEAD_FEAT_ELEMS;
        fclose(f);
        CHECK(ok, "read head_synth_feat.bin");

        float el[3], ep[3];
        int eam = -1;
        f = fopen("tests/data/head_synth_expect.txt", "r");
        ok = f && fscanf(f, "%f %f %f", &el[0], &el[1], &el[2]) == 3
              && fscanf(f, "%f %f %f", &ep[0], &ep[1], &ep[2]) == 3
              && fscanf(f, "%d", &eam) == 1;
        fclose(f);
        CHECK(ok, "read head_synth_expect.txt");

        float logits[3], probs[3];
        int cls = mfl_head_forward(&w, feat, logits, probs);
        float md = 0.0f, mp = 0.0f;
        for (int i = 0; i < 3; i++) {
            float d = fabsf(logits[i] - el[i]);
            if (d > md) md = d;
            d = fabsf(probs[i] - ep[i]);
            if (d > mp) mp = d;
        }
        printf("    logits C vs numpy-ref: %.6f %.6f %.6f (max|d|=%.2e)\n",
               logits[0], logits[1], logits[2], md);
        CHECK(md < 1e-4f, "logits match numpy mirror (|d|<1e-4)");
        CHECK(mp < 1e-4f, "softmax match numpy mirror");
        CHECK(cls == eam, "argmax match");

        float lg2[3], pr2[3];
        int cls2 = mfl_head_forward(&w, feat, lg2, pr2);
        CHECK(memcmp(logits, lg2, sizeof lg2) == 0 && memcmp(probs, pr2, sizeof pr2) == 0
              && cls == cls2, "deterministic forward");
        float s = probs[0] + probs[1] + probs[2];
        CHECK(fabsf(s - 1.0f) < 1e-5f && probs[0] >= 0 && probs[1] >= 0
              && probs[2] >= 0, "softmax sums to 1, non-negative");
        CHECK(mfl_head_forward(&w, NULL, logits, NULL) == -1, "NULL feat rejected");

        free(feat);
    }

    mfl_head_release(owner);

    printf(n_fail ? "RESULT: %d FAILURE(S)\n" : "RESULT: ALL PASS\n", n_fail);
    return n_fail ? 1 : 0;
}
