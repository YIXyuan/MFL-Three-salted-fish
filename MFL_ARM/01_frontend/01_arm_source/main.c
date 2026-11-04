#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "preprocess.h"
#include "head.h"
#include "fpga_if.h"
#include "report.h"

typedef struct {
    int   mode;
    const char *watch_dir;
    const char *manifest;
    const char *stub_dir;
    unsigned long reg_base;
    const char *head_weights;
    const char *captures_dir;
    const char *csv_out;
    const char *fail_csv;
    int   health_wait_s;
    int   interval_ms;
    int   max_sweeps;
    mfl_report_cfg rep;
    int   arm_pool;
} cfg_t;

static volatile sig_atomic_t g_stop = 0;
static void on_sigint(int sig) { (void)sig; g_stop = 1; }

typedef struct {
    char new_name[64];
    char point_id[8];
    int  severity;
} mrow_t;

static mrow_t *g_rows  = NULL;
static long    g_nrows = 0;
static char  **g_order = NULL;
static long    g_norder = 0;

static int manifest_load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "[main] manifest 打不开: %s (%s)\n", path,
                strerror(errno));
        return -1;
    }
    char line[512];
    long cap = 256, n = 0;
    g_rows = malloc(sizeof(mrow_t) * (size_t)cap);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "\xEF\xBB\xBF", 3) == 0) memmove(line, line + 3, strlen(line + 3) + 1);
        if (strncmp(line, "feed_order", 10) == 0) continue;
        mrow_t r;
        int consumed = 0;
        if (sscanf(line, "%*d,%*d,%63[^,],%*[^,],%7[^,],%d%n",
                   r.new_name, r.point_id, &r.severity, &consumed) >= 3 &&
            r.new_name[0]) {
            if (n == cap) {
                cap *= 2;
                g_rows = realloc(g_rows, sizeof(mrow_t) * (size_t)cap);
            }
            g_rows[n++] = r;
        }
    }
    fclose(f);
    g_nrows = n;
    fprintf(stderr, "[main] manifest 载入 %ld 行: %s\n", n, path);
    return n > 0 ? 0 : -1;
}

static const mrow_t *manifest_find(const char *new_name)
{
    for (long i = 0; i < g_nrows; i++)
        if (strcmp(g_rows[i].new_name, new_name) == 0) return &g_rows[i];
    return NULL;
}

static int feed_order_load(const char *dir)
{
    char path[1024];
    snprintf(path, sizeof(path), "%s/feed_order.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512];
    long cap = 256, n = 0;
    g_order = malloc(sizeof(char *) * (size_t)cap);
    while (fgets(line, sizeof(line), f)) {
        size_t l = strlen(line);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = '\0';
        if (!l) continue;
        if (n == cap) {
            cap *= 2;
            g_order = realloc(g_order, sizeof(char *) * (size_t)cap);
        }
        g_order[n++] = strdup(line);
    }
    fclose(f);
    g_norder = n;
    fprintf(stderr, "[main] feed_order 载入 %ld 行(轮巡剧本)\n", n);
    return n > 0 ? 0 : -1;
}

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static long long wall_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int file_fresh(const char *dir, const char *name)
{
    char p[1024];
    struct stat st;
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    if (stat(p, &st) != 0) return 0;
    return (wall_ms() - (long long)st.st_mtim.tv_sec * 1000
            - st.st_mtim.tv_nsec / 1000000) < 600;
}

static int point_id_from_name(const char *name, char *pid)
{
    if (strlen(name) < 9 || name[0] != 'P') return -1;
    for (int i = 1; i <= 4; i++)
        if (name[i] < '0' || name[i] > '9') return -1;
    int v = (name[1] - '0') * 1000 + (name[2] - '0') * 100
          + (name[3] - '0') * 10   + (name[4] - '0');
    if (v < 1 || v > 1861) return -1;
    memcpy(pid, name, 5);
    pid[5] = '\0';
    return 0;
}

static int rename_ext(const char *dir, const char *name, const char *suffix)
{
    char a[1024], b[1104];
    snprintf(a, sizeof(a), "%s/%s", dir, name);
    snprintf(b, sizeof(b), "%s.%s", a, suffix);
    if (rename(a, b) != 0)
        fprintf(stderr, "[main] 改名失败 %s→%s: %s\n", a, b, strerror(errno));
    return 0;
}

static int copy_file(const char *src, const char *dst)
{
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        if (fwrite(buf, 1, n, out) != n) { fclose(in); fclose(out); return -1; }
    fclose(in);
    fclose(out);
    return 0;
}

static void mkdirs(const char *path)
{
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t l = strlen(tmp);
    if (l && tmp[l - 1] == '/') tmp[l - 1] = '\0';
    for (char *p = tmp + 1; *p; p++)
        if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
    mkdir(tmp, 0755);
}

static int cmp_str(const void *a, const void *b)
{ return strcmp(*(const char *const *)a, *(const char *const *)b); }

static int ext_ok(char *name)
{
    char *dot = strrchr(name, '.');
    if (!dot) return 0;
    for (char *e = dot + 1; *e; e++) *e = (char)tolower((unsigned char)*e);
    return strcmp(dot + 1, "jpg") == 0 || strcmp(dot + 1, "jpeg") == 0 ||
           strcmp(dot + 1, "png") == 0  || strcmp(dot + 1, "bmp") == 0;
}

static char **scan_images(const char *dir, int *out_n)
{
    DIR *d = opendir(dir);
    if (!d) {
        fprintf(stderr, "[main] watch-dir 打不开: %s\n", dir);
        *out_n = 0;
        return NULL;
    }
    char **list = NULL;
    int n = 0, cap = 256;
    list = malloc(sizeof(char *) * (size_t)cap);
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;
        char tmp[300];
        snprintf(tmp, sizeof(tmp), "%s", de->d_name);
        if (!ext_ok(tmp)) continue;
        if (n == cap) {
            cap *= 2;
            list = realloc(list, sizeof(char *) * (size_t)cap);
        }
        list[n++] = strdup(de->d_name);
    }
    closedir(d);
    if (n > 1) qsort(list, (size_t)n, sizeof(char *), cmp_str);
    *out_n = n;
    return list;
}

typedef struct {
    long n_frames, n_ok, n_skip, n_report_fail;
    long long t0;
    FILE *csv;
} stats_t;

static void end_log(const stats_t *st)
{
    double sec = (now_ms() - st->t0) / 1000.0;
    if (st->n_frames > 0)
        fprintf(stderr,
                "[main] 结束: frames=%ld ok=%ld skip=%ld report_fail=%ld, "
                "用时 %.1fs (%.2f FPS 含预处理)\n",
                st->n_frames, st->n_ok, st->n_skip, st->n_report_fail,
                sec, st->n_frames / sec);
    else
        fprintf(stderr,
                "[main] 结束: frames=%ld ok=%ld skip=%ld report_fail=%ld, "
                "用时 %.1fs\n",
                st->n_frames, st->n_ok, st->n_skip, st->n_report_fail, sec);
}

static void emit_result(const cfg_t *c, stats_t *st, const char *name,
                        int pred, const float *probs, const char *src,
                        int rename_done)
{
    char pid[8];
    if (point_id_from_name(name, pid) != 0) {
        fprintf(stderr, "[main] 非法文件名(无合法 point_id), 跳过: %s\n", name);
        st->n_skip++;
        return;
    }
    if (mfl_report_detection(&c->rep, pid, pred) != 0)
        st->n_report_fail++;

    char dst[1024];
    snprintf(dst, sizeof(dst), "%s/%s", c->captures_dir, name);
    if (access(dst, F_OK) != 0)
        copy_file(src, dst);

    if (st->csv) {
        int plan = -1;
        const mrow_t *r = manifest_find(name);
        if (r) plan = r->severity;
        fprintf(st->csv, "%s,%d,%d,%.4f,%.4f,%.4f,%d\n", name, plan, pred,
                probs ? probs[0] : 0.0f, probs ? probs[1] : 0.0f,
                probs ? probs[2] : 0.0f, plan == pred);
        fflush(st->csv);
    }
    if (rename_done) rename_ext(c->watch_dir, name, "done");
    st->n_ok++;
}

static int run_replay(const cfg_t *c)
{
    if (manifest_load(c->manifest) != 0) return 2;
    if (feed_order_load(c->watch_dir) != 0) {
        fprintf(stderr, "[main] replay 需要 feed_order.txt(剧本播放器), "
                "%s 下未找到\n", c->watch_dir);
        return 2;
    }
    fprintf(stderr, "[main] replay: 不做 .done 改名(剧本无限轮巡), "
            "interval=%dms, max_sweeps=%d\n",
            c->interval_ms, c->max_sweeps);

    stats_t st;
    memset(&st, 0, sizeof(st));
    st.t0 = now_ms();
    if (c->manifest && c->manifest[0]) {
        st.csv = fopen(c->csv_out, "w");
        if (st.csv) {
            fprintf(st.csv, "new_name,plan,pred,p0,p1,p2,match\n");
            fflush(st.csv);
        }
    }

    int sweep = 0;
    long idx = 0;
    while (!g_stop) {
        if (idx >= g_norder) {
            sweep++;
            fprintf(stderr, "[main] 第 %d 轮完: ok=%ld skip=%ld\n",
                    sweep, st.n_ok, st.n_skip);
            if (c->max_sweeps > 0 && sweep >= c->max_sweeps) break;
            idx = 0;
            if (g_norder == 0) break;
        }
        const char *name = g_order[idx++];
        const mrow_t *r = manifest_find(name);
        if (!r) {
            fprintf(stderr, "[main] %s 不在 manifest, 跳过\n", name);
            st.n_skip++;
            continue;
        }
        char src[1024];
        snprintf(src, sizeof(src), "%s/%s", c->watch_dir, name);
        if (access(src, F_OK) != 0) {
            fprintf(stderr, "[main] 缺图: %s\n", src);
            st.n_skip++;
            continue;
        }
        emit_result(c, &st, name, r->severity, NULL, src, 0);
        if (c->interval_ms > 0)
            usleep((useconds_t)c->interval_ms * 1000);
    }
    if (st.csv) fclose(st.csv);
    end_log(&st);
    return 0;
}

#define DRAIN_SLOT(s) do {                                                     \
    if (slots[(s)].busy) {                                                     \
        const int8_t *outp = mfl_fpga_wait_complete((s));                      \
        if (outp) {                                                            \
            const int8_t *feat_in;                                             \
            int8_t feat[MFL_HEAD_FEAT_ELEMS];                                  \
            if (c->arm_pool) {                                                 \
                mfl_relu_pool5(outp, feat);                                    \
                feat_in = feat;                                            \
            } else {                                                           \
                feat_in = outp;                                              \
            }                                                                  \
            float logits[3], probs[3];                                         \
            int pred = mfl_head_forward(&hw, feat_in, logits, probs);          \
            char src[1024];                                                    \
            snprintf(src, sizeof(src), "%s/%s", c->watch_dir,                  \
                     slots[(s)].name);                                         \
            emit_result(c, &st, slots[(s)].name, pred, probs, src, 1);         \
        } else {                                                               \
            fprintf(stderr, "[main] slot%d FPGA 超时/失败: %s\n", (s),         \
                    slots[(s)].name);                                          \
            rename_ext(c->watch_dir, slots[(s)].name, "bad");                  \
            st.n_skip++;                                                       \
        }                                                                      \
        slots[(s)].busy = 0;                                                   \
    }                                                                          \
} while (0)

static int run_infer(const cfg_t *c)
{
    if (c->manifest && c->manifest[0] && manifest_load(c->manifest) != 0)
        fprintf(stderr, "[main] --plan 装载失败, CSV 里 plan 列将全为 -1\n");

    mfl_fpga_set_layer(c->arm_pool ? MFL_LAYER_ARM_POOL : MFL_LAYER_FULL);
    if (mfl_fpga_init(c->stub_dir, c->reg_base) != MFL_FPGA_OK) {
        fprintf(stderr, "[main] FPGA 初始化失败(实模式需 fabric 就绪; "
                "彩排期用 --stub-vectors <dir>)\n");
        return 2;
    }
    MflHeadWeights hw;
    void *owner = NULL;
    if (mfl_head_load(c->head_weights, &hw, &owner) != 0) {
        fprintf(stderr, "[main] head 权重装载失败: %s\n", c->head_weights);
        mfl_fpga_deinit();
        return 2;
    }

    stats_t st;
    memset(&st, 0, sizeof(st));
    st.t0 = now_ms();
    if (c->manifest && c->manifest[0]) {
        st.csv = fopen(c->csv_out, "w");
        if (st.csv) {
            fprintf(st.csv, "new_name,plan,pred,p0,p1,p2,match\n");
            fflush(st.csv);
        }
    }

    struct { int busy; char name[300]; } slots[2];
    slots[0].busy = slots[1].busy = 0;

    char **list = NULL;
    int nlist = 0;
    if (g_norder == 0) {
        list = scan_images(c->watch_dir, &nlist);
        fprintf(stderr, "[main] 无 feed_order, 扫描 %d 个待处理文件\n", nlist);
    }

    int sweep = 0;
    long idx = 0;
    while (!g_stop) {
        const char *name = NULL;
        if (g_norder > 0) {
            if (idx >= g_norder) {
                sweep++;
                fprintf(stderr, "[main] 第 %d 轮完: ok=%ld skip=%ld\n",
                        sweep, st.n_ok, st.n_skip);
                if (c->max_sweeps > 0 && sweep >= c->max_sweeps) break;
                idx = 0;
            }
            name = g_order[idx++];
            char p[1104];
            snprintf(p, sizeof(p), "%s/%s", c->watch_dir, name);
            if (access(p, F_OK) != 0) {
                snprintf(p, sizeof(p), "%s/%s.done", c->watch_dir, name);
                if (access(p, F_OK) == 0) continue;
                fprintf(stderr, "[main] 缺图: %s\n", name);
                st.n_skip++;
                continue;
            }
        } else {
            if (idx >= nlist) break;
            name = list[idx++];
        }
        if (!name) continue;
        st.n_frames++;

        if (file_fresh(c->watch_dir, name)) {
            fprintf(stderr, "[main] %s 传输中, 延后\n", name);
            st.n_skip++; idx--; usleep(50000); continue;
        }

        int slot = (slots[0].busy == 0) ? 0 : 1;
        if (slots[0].busy || slots[1].busy) {
            DRAIN_SLOT(0);
            DRAIN_SLOT(1);
            slot = 0;
        }

        int8_t *inb = mfl_fpga_in_buf(slot);
        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", c->watch_dir, name);
        int rc = mfl_preprocess_file(path, inb);
        if (rc != MFL_OK) {
            fprintf(stderr, "[main] 预处理失败(%d): %s\n", rc, name);
            rename_ext(c->watch_dir, name, "bad");
            st.n_skip++;
            continue;
        }
        if (mfl_fpga_submit(slot, name) != MFL_FPGA_OK) {
            fprintf(stderr, "[main] submit 失败: %s\n", name);
            rename_ext(c->watch_dir, name, "bad");
            st.n_skip++;
            continue;
        }
        snprintf(slots[slot].name, sizeof(slots[slot].name), "%s", name);
        slots[slot].busy = 1;

        DRAIN_SLOT(slot ^ 1);

        if (st.n_frames % 100 == 0)
            fprintf(stderr, "[main] %ld 帧 ok=%ld skip=%ld fail=%ld %.1fs\n",
                    st.n_frames, st.n_ok, st.n_skip, st.n_report_fail,
                    (now_ms() - st.t0) / 1000.0);
    }
    DRAIN_SLOT(0);
    DRAIN_SLOT(1);

    if (st.csv) fclose(st.csv);
    mfl_fpga_deinit();
    for (int i = 0; i < nlist; i++) free(list[i]);
    free(list);
    end_log(&st);
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "用法: %s [选项]\n"
        "  --mode infer|replay        默认 infer\n"
        "  --watch-dir <dir>          输入目录, 默认 /root/sd_in\n"
        "  --stub-vectors <dir>       FPGA stub: conv09 向量目录(无 fabric 联调用)\n"
        "  --reg-base <hex>           实模式寄存器基址(默认占位 0x%lx)\n"
        "  --head-weights <file>      默认 weights/mfl_head.bin\n"
        "  --plan <manifest.csv>      infer 叠加对照 CSV(replay 模式给 manifest 路径)\n"
        "  --csv-out <file>           对照 CSV 输出, 默认 plan_log.csv\n"
        "  --backend <ip:port>        Web 后端, 默认 127.0.0.1:8080\n"
        "  --captures-dir <dir>       归档目录, 默认 /root/mflweb/data/captures\n"
        "  --fail-csv <file>          上报失败兜底, 默认 report_failed.csv\n"
        "  --health-wait <sec>        启动等后端秒数(0=不等), 默认 10\n"
        "  --interval-ms <ms>         replay 节奏(默认 100); infer 默认 0\n"
        "  --max-sweeps <n>           feed_order 轮数(0=∞); 无 feed_order 时单遍\n",
        argv0, (unsigned long)MFL_REG_BASE_DEFAULT);
}

int main(int argc, char **argv)
{
    cfg_t c;
    memset(&c, 0, sizeof(c));
    c.mode = 0;
    c.watch_dir = "/root/sd_in";
    c.manifest = NULL;
    c.stub_dir = NULL;
    c.reg_base = 0;
    c.head_weights = "weights/mfl_head.bin";
    c.captures_dir = "/root/mflweb/data/captures";
    c.csv_out = "plan_log.csv";
    c.fail_csv = "report_failed.csv";

    c.health_wait_s = 10;
    c.interval_ms = -1;
    c.max_sweeps = 0;
    c.arm_pool = -1;
    snprintf(c.rep.host, sizeof(c.rep.host), "127.0.0.1");
    c.rep.port = 8080;
    c.rep.timeout_ms = 3000;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define NEED(v) do { if (i + 1 >= argc) { \
            fprintf(stderr, "[main] %s 缺参数\n", a); return 1; } \
            (v) = argv[++i]; } while (0)
        if      (!strcmp(a, "--mode")) {
            const char *m;
            NEED(m);
            if (!strcmp(m, "replay")) c.mode = 1;
            else if (!strcmp(m, "infer")) c.mode = 0;
            else { fprintf(stderr, "[main] 未知模式: %s\n", m); return 1; }
        }
        else if (!strcmp(a, "--plan"))          NEED(c.manifest);
        else if (!strcmp(a, "--watch-dir"))     NEED(c.watch_dir);
        else if (!strcmp(a, "--stub-vectors"))  NEED(c.stub_dir);
        else if (!strcmp(a, "--head-weights"))  NEED(c.head_weights);
        else if (!strcmp(a, "--csv-out"))       NEED(c.csv_out);
        else if (!strcmp(a, "--captures-dir"))  NEED(c.captures_dir);
        else if (!strcmp(a, "--fail-csv"))      NEED(c.fail_csv);
        else if (!strcmp(a, "--backend")) {
            char *bp;
            NEED(bp);
            char *colon = strchr(bp, ':');
            if (colon) {
                *colon = '\0';
                c.rep.port = atoi(colon + 1);
            }
            snprintf(c.rep.host, sizeof(c.rep.host), "%s", bp);
        }
        else if (!strcmp(a, "--arm-pool"))      c.arm_pool = 1;
        else if (!strcmp(a, "--reg-base"))      c.reg_base = strtoul(argv[++i], NULL, 16);
        else if (!strcmp(a, "--health-wait"))   c.health_wait_s = atoi(argv[++i]);
        else if (!strcmp(a, "--interval-ms"))   c.interval_ms = atoi(argv[++i]);
        else if (!strcmp(a, "--max-sweeps"))    c.max_sweeps = atoi(argv[++i]);
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "[main] 未知参数: %s\n", a); usage(argv[0]); return 1; }
        #undef NEED
    }
    if (c.arm_pool < 0)
        c.arm_pool = (c.stub_dir != NULL);
    if (c.interval_ms < 0) c.interval_ms = (c.mode == 1) ? 100 : 0;
    snprintf(c.rep.fail_csv, sizeof(c.rep.fail_csv), "%s", c.fail_csv);

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    mkdirs(c.captures_dir);

    mfl_report_wait_health(&c.rep, c.health_wait_s, 1000);

    int rc = (c.mode == 1) ? run_replay(&c) : run_infer(&c);

    for (long i = 0; i < g_norder; i++) free(g_order[i]);
    free(g_order);
    free(g_rows);
    return rc;
}
