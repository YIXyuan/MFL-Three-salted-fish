#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include "head.h"
#include "quant_params.h"
#include "fpga_if.h"

#define N_FEAT   (FEAT_C * FEAT_H * FEAT_W)
#define N_FEAT30 (FEAT_C * 30 * 64)
#define N_INPUT  (3 * 480 * 1024)

static void print_csv_header(FILE *csv)
{
    fprintf(csv, "name,logit0,logit1,logit2,pred,conf,prob0,prob1,prob2\n");
}

static void emit(const char *name, const mfl_head_result_t *r, FILE *csv)
{
    printf("%-26s pred=%d conf=%.4f logits=[%+.4f %+.4f %+.4f] probs=[%.4f %.4f %.4f]\n",
           name, r->pred, r->conf, r->logits[0], r->logits[1], r->logits[2],
           r->probs[0], r->probs[1], r->probs[2]);
    if (csv)
        fprintf(csv, "%s,%.6f,%.6f,%.6f,%d,%.6f,%.6f,%.6f,%.6f\n",
                name, r->logits[0], r->logits[1], r->logits[2],
                r->pred, r->conf, r->probs[0], r->probs[1], r->probs[2]);
}

static int load_file(const char *path, void *buf, size_t expect)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); return -1; }
    size_t n = fread(buf, 1, expect, f);
    int extra = fgetc(f);
    fclose(f);
    if (n != expect || extra != EOF) {
        fprintf(stderr, "%s 大小不符: 期望 %zu 字节, 读到 %zu\n", path, expect, n);
        return -2;
    }
    return 0;
}

static double now_ms(void)
{
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void usage(const char *prog){
    printf("用法:\n"
           "  离线: %s -w head_weights.bin -f feat_int8.bin [--feat30] [-n NAME] [-c OUT.csv]\n"
           "  在线: %s -w head_weights.bin -i input_int8.bin --fpga\n"
           "          [--slot 0|1] [--layer 0xFF] [--loop N] [--timeout 15000]\n"
           "          [--no-reset-retry] [-c OUT.csv]\n"
           "  探测: %s --probe-uio        (只读, 打印 VERSION 与邮箱 8 字)\n"
           "  布局覆盖 (中间版位流用): --window-phys/--window-size/--mailbox-off\n"
           "          --in-off/--in-off2/--out-off  (默认取 v3.2 定案值)\n"
           "  其它: --dump <file> 在线完成时把 OUT 原始字节导出\n"
           "        --feat30 离线输入按旧格式 96x30x64 处理 (内部 ReLU+2x2 pool)\n"
           "  LAYER: 0xFF 全链(15x32) / 0x2FF 跳池化(30x64) / 0x1FF 跳ReLU / 0x300|N 逐层\n",
           prog, prog, prog);
}

int main(int argc, char **argv)
{
    const char *wpath = NULL, *feat_path = NULL, *in_path = NULL, *csv_path = NULL;
    const char *dump_path = NULL, *name = "frame";
    int use_fpga = 0, slot = 0, loops = 1, feat30 = 0, probe = 0;
    int reset_retry = 1;
    uint32_t layer = FPGA_LAYER_FULL;
    mfl_fpga_cfg_t cfg;
    mfl_fpga_cfg_default(&cfg);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-w") && i + 1 < argc)       wpath = argv[++i];
        else if (!strcmp(argv[i], "-f") && i + 1 < argc)  feat_path = argv[++i];
        else if (!strcmp(argv[i], "-i") && i + 1 < argc)  in_path = argv[++i];
        else if (!strcmp(argv[i], "-n") && i + 1 < argc)  name = argv[++i];
        else if (!strcmp(argv[i], "-c") && i + 1 < argc)  csv_path = argv[++i];
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump_path = argv[++i];
        else if (!strcmp(argv[i], "--slot") && i + 1 < argc) slot = atoi(argv[++i]) ? 1 : 0;
        else if (!strcmp(argv[i], "--loop") && i + 1 < argc) loops = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) cfg.timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--layer") && i + 1 < argc) layer = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--window-phys") && i + 1 < argc) cfg.window_phys = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--window-size") && i + 1 < argc) cfg.window_size = (size_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--mailbox-off") && i + 1 < argc) cfg.mailbox_off = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--in-off") && i + 1 < argc) cfg.in_off[0] = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--in-off2") && i + 1 < argc) cfg.in_off[1] = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--out-off") && i + 1 < argc) cfg.out_off = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--feat30"))            feat30 = 1;
        else if (!strcmp(argv[i], "--no-reset-retry"))    reset_retry = 0;
        else if (!strcmp(argv[i], "--probe-uio"))         probe = 1;
        else if (!strcmp(argv[i], "--fpga"))              use_fpga = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "未知参数 %s\n", argv[i]); usage(argv[0]); return 2; }
    }

    if (probe) {
        mfl_fpga_t f;
        if (mfl_fpga_open(&f, "/dev/uio0", &cfg) != 0) {
            fprintf(stderr, "UIO 映射失败\n");
            return 1;
        }
        uint32_t m[8];
        mfl_fpga_dump_mailbox(&f, m);
        printf("uio mmap OK: base=%p size=0x%zx mailbox=+0x%x\n",
               (void *)f.shared, cfg.window_size, cfg.mailbox_off);
        printf("VERSION = 0x%08x  (%s)\n", m[6],
               !mfl_fpga_version_valid(m[6]) ? "非法/疑似位流未加载或邮箱未译码"
               : m[6] ? "有效, RESET 可用" : "有效, RESET 未实现(旧位流)");
        printf("邮箱: IN=0x%08x OUT=0x%08x SLOT=0x%08x CTRL=0x%08x\n"
               "      STATUS=0x%x LAYER=0x%x VERSION=0x%08x RESET=0x%08x\n",
               m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]);
        mfl_fpga_close(&f);
        return 0;
    }

    if (!wpath) { usage(argv[0]); return 2; }
    int rc = mfl_head_load(wpath);
    if (rc != 0) { fprintf(stderr, "加载权重失败 rc=%d\n", rc); return 1; }

    FILE *csv = csv_path ? fopen(csv_path, "w") : NULL;
    if (csv) print_csv_header(csv);

    static int8_t feat[N_FEAT30];
    static int8_t pooled[N_FEAT];
    mfl_head_result_t r;

    if (!use_fpga) {
        if (!feat_path) { usage(argv[0]); return 2; }
        if (feat30) {
            if (load_file(feat_path, feat, N_FEAT30) != 0) return 1;
            mfl_head_pool2_int8(feat, pooled);
            mfl_head_run(pooled, &r);
        } else {
            if (load_file(feat_path, feat, N_FEAT) != 0) return 1;
            mfl_head_run(feat, &r);
        }
        emit(feat_path, &r, csv);
    } else {
        if (!in_path) { fprintf(stderr, "在线模式需要 -i 输入张量\n"); return 2; }
        if ((layer & 0x300u) == 0x300u) {
            fprintf(stderr, "LAYER=0x%x 是逐层导出模式, 不做分类\n", layer);
            return 2;
        }

        static int8_t input[N_INPUT];
        if (load_file(in_path, input, sizeof(input)) != 0) return 1;

        mfl_fpga_t fpga;
        if (mfl_fpga_open(&fpga, "/dev/uio0", &cfg) != 0) {
            fprintf(stderr, "打开 FPGA 通道失败\n");
            return 1;
        }
        printf("FPGA v3.2: window=0x%08x OUT=+0x%x VERSION=0x%08x (%s)\n",
               cfg.window_phys, cfg.out_off, fpga.version,
               !mfl_fpga_version_valid(fpga.version) ? "非法/位流未加载" :
               fpga.version ? "RESET 可用" : "RESET 未实现");

        for (int it = 0; it < loops; it++) {
            for (int attempt = 0; ; attempt++) {
                double t0 = now_ms();
                if (mfl_fpga_submit(&fpga, slot, input, sizeof(input), layer) != 0) {
                    fprintf(stderr, "提交失败\n");
                    goto done;
                }
                int wr = mfl_fpga_wait_done(&fpga, cfg.timeout_ms);
                double dt = now_ms() - t0;
                if (wr == 0) {
                    printf("  frame %d: done, %.1f ms\n", it, dt);
                    break;
                }

                fprintf(stderr, "第 %d 帧失败: %s (%.1f ms)\n", it,
                        wr == -1 ? "超时" : wr == -2 ? "ERR 置位(OUT 无效)" : "未定义状态", dt);
                if (wr == -1 && reset_retry && attempt == 0 &&
                    FPGA_VERSION_RESET_AVAILABLE(fpga.version)) {
                    fprintf(stderr, "尝试软复位...\n");
                    int rr = mfl_fpga_reset(&fpga);
                    fprintf(stderr, "软复位: %s\n",
                            rr == 0 ? "成功, 重走写序" :
                            rr == -1 ? "RESET 不可用" :
                            rr == -2 ? "1s 超时" : "RESET_FAIL");
                    if (rr == 0) continue;
                }
                goto done;
            }

            const int8_t *out = mfl_fpga_out_buf(&fpga);
            char label[64];
            snprintf(label, sizeof(label), "%s#%d", name, it);

            if (dump_path) {
                size_t n = (layer & 0x200u) ? FPGA_OUT_BYTES_30 : FPGA_OUT_BYTES;
                FILE *df = fopen(dump_path, (it == 0) ? "wb" : "ab");
                if (df) { fwrite(out, 1, n, df); fclose(df); }
            }

            if (layer & 0x200u) {
                memcpy(feat, out, N_FEAT30);
                mfl_head_pool2_int8(feat, pooled);
                mfl_head_run(pooled, &r);
            } else {
                mfl_head_run(out, &r);
            }
            emit(label, &r, csv);
        }
done:
        mfl_fpga_close(&fpga);
    }

    if (csv) fclose(csv);
    return 0;
}
