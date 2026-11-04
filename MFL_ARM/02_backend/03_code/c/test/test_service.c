#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "head_service.h"
#include "quant_params.h"

#define N_FEAT  (FEAT_C * FEAT_H * FEAT_W)
#define N_FEAT30 (FEAT_C * 30 * 64)

static int load_file(const char *path, void *buf, size_t expect)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); return -1; }
    size_t n = fread(buf, 1, expect, f);
    int extra = fgetc(f);
    fclose(f);
    if (n != expect || extra != EOF) {
        fprintf(stderr, "%s 大小不符: 期望 %zu, 读到 %zu\n", path, expect, n);
        return -2;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <weights> <feat.bin> [--feat30] [--point ID] "
                        "[--name FILE] [--server host:port] [--csv out.csv]\n", argv[0]);
        return 2;
    }

    mfl_service_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.weights_path = argv[1];
    cfg.server_port = 0;
    cfg.timeout_ms = 500;
    cfg.retries = 1;

    int is30 = 0;
    const char *feat_path = argv[2];
    const char *point = NULL, *image = NULL;
    char host[64] = { 0 };

    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--feat30")) is30 = 1;
        else if (!strcmp(argv[i], "--point") && i + 1 < argc) point = argv[++i];
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) image = argv[++i];
        else if (!strcmp(argv[i], "--csv") && i + 1 < argc) cfg.csv_path = argv[++i];
        else if (!strcmp(argv[i], "--retries") && i + 1 < argc) cfg.retries = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) cfg.timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--server") && i + 1 < argc) {
            const char *s = argv[++i];
            const char *colon = strrchr(s, ':');
            if (!colon) { fprintf(stderr, "server 需为 host:port\n"); return 2; }
            size_t hl = (size_t)(colon - s);
            if (hl >= sizeof(host)) hl = sizeof(host) - 1;
            memcpy(host, s, hl); host[hl] = 0;
            cfg.server_host = host;
            cfg.server_port = atoi(colon + 1);
        } else {
            fprintf(stderr, "未知参数 %s\n", argv[i]);
            return 2;
        }
    }

    char pid[64];
    if (!point && image && mfl_point_id_from_name(image, pid, sizeof(pid)) == 0)
        point = pid;

    int rc = mfl_service_init(&cfg);
    if (rc != 0) { fprintf(stderr, "service init 失败 rc=%d\n", rc); return 1; }

    static int8_t feat[N_FEAT30];
    mfl_service_result_t r;
    if (is30) {
        if (load_file(feat_path, feat, N_FEAT30) != 0) return 1;
        rc = mfl_service_run30(feat, point, image, &r);
    } else {
        if (load_file(feat_path, feat, N_FEAT) != 0) return 1;
        rc = mfl_service_run15(feat, point, image, &r);
    }
    if (rc != 0) { fprintf(stderr, "service run 失败 rc=%d\n", rc); return 1; }

    printf("point_id = %s\n", point ? point : "(无)");
    printf("pred     = %d (%s / %s), severity=%d\n",
           r.head.pred, r.label, mfl_class_label_zh(r.head.pred), r.severity);
    printf("logits   = [%+.6f %+.6f %+.6f]\n",
           r.head.logits[0], r.head.logits[1], r.head.logits[2]);
    printf("probs    = [%.6f %.6f %.6f]  conf=%.6f\n",
           r.head.probs[0], r.head.probs[1], r.head.probs[2], r.head.conf);
    printf("post     = %d (%s)\n", r.post_status,
           r.post_status == MFL_POST_OK ? "ok" :
           r.post_status == MFL_POST_DISABLED ? "disabled" : "failed");
    printf("ts_ms    = %lld\n", r.ts_ms);

    mfl_service_close();
    return 0;
}
