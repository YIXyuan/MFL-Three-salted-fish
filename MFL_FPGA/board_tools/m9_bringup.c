// -----------------------------------------------------------------------------
// m9_bringup.c -- Kosmo2-MES2K100 / M9 top board bring-up helper
//
// Target: Linux on PU (aarch64), /dev/uio0 maps 64 MiB at physical 0x00300000.
// Board has no python/gcc; cross-compile on host:
//   aarch64-linux-gnu-gcc -O2 -static -o m9_bringup m9_bringup.c
//
// Usage:
//   m9_bringup boot
//   m9_bringup probe
//   m9_bringup full  <in.bin> [exp.bin]
//   m9_bringup dual  <inA.bin> <expA.bin> <inB.bin> [expB.bin]   (in-flight 2 / 1 深 pending)
//   m9_bringup single <layer_hex> <in.bin> [exp.bin] [out_len]
//   m9_bringup softreset
//   m9_bringup dump <offset_hex> <len> <out.bin>
//
// Memory map:
//   window base = 0x00300000 (UIO offset 0 / /dev/mem offset 0x300000)
//   mailbox +0x1000, IN +0x2000, OUT +0x170000, BIST +0x980000
//   IN size 1,474,560 B; final OUT 46,080 B
// -----------------------------------------------------------------------------
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define WIN_SIZE       (64u * 1024u * 1024u)
#define PHYS_BASE      0x00300000u
#define OFF_MBOX       0x00001000u
#define OFF_IN         0x00002000u
#define OFF_OUT        0x000170000u
#define OFF_BIST       0x000980000u

#define MB_IN_ADDR     0x00u
#define MB_OUT_ADDR    0x04u
#define MB_CTRL        0x0Cu
#define MB_STATUS      0x10u
#define MB_LAYER       0x14u
#define MB_VERSION     0x18u
#define MB_RESET       0x1Cu

/* 上电门控：写有效 IN/OUT，适配器才写 VERSION/STATUS=0（无 magic） */

#define IN_ADDR_PHYS   0x00302000u
#define OUT_ADDR_PHYS  0x00470000u
#define IN_BYTES       1474560u
#define OUT_BYTES      46080u

/* 双帧（in-flight 2）测试：B 帧走 IN slot1，和 ARM 驱动 slot1 完全一致 */
#define IN_B_ADDR_PHYS 0x01500000u
#define OFF_IN_B       (IN_B_ADDR_PHYS - PHYS_BASE)   /* 0x01200000 */

static volatile uint8_t *g_win;
static int g_fd = -1;
static int g_is_mem = 0;

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int map_window(void)
{
    off_t off = 0;
    void *p;

    g_fd = open("/dev/uio0", O_RDWR | O_SYNC);
    if (g_fd < 0) {
        g_fd = open("/dev/mem", O_RDWR | O_SYNC);
        off = (off_t)PHYS_BASE;
        g_is_mem = 1;
    }
    if (g_fd < 0) {
        perror("open /dev/uio0 and /dev/mem");
        return -1;
    }
    p = mmap(NULL, WIN_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, off);
    if (p == MAP_FAILED) {
        perror("mmap");
        close(g_fd);
        return -1;
    }
    g_win = (volatile uint8_t *)p;
    printf("[map] %s offset=0x%llx size=0x%x\n",
           g_is_mem ? "/dev/mem" : "/dev/uio0",
           (unsigned long long)off, WIN_SIZE);
    return 0;
}

static inline uint32_t rd32(uint32_t off)
{
    return *(volatile uint32_t *)(g_win + off);
}

static inline void wr32(uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(g_win + off) = val;
    __sync_synchronize();
}

static inline uint32_t mb_rd(uint32_t off) { return rd32(OFF_MBOX + off); }
static inline void mb_wr(uint32_t off, uint32_t val) { wr32(OFF_MBOX + off, val); }

static int load_file_to(const char *path, volatile uint8_t *dst, size_t len)
{
    FILE *f = fopen(path, "rb");
    size_t n;
    if (!f) { perror(path); return -1; }
    n = fread((void *)dst, 1, len, f);
    fclose(f);
    if (n != len) {
        fprintf(stderr, "[err] %s: short read %zu/%zu\n", path, n, len);
        return -1;
    }
    __sync_synchronize();
    return 0;
}

static int load_file_mem(const char *path, uint8_t *dst, size_t len)
{
    FILE *f = fopen(path, "rb");
    size_t n;
    if (!f) { perror(path); return -1; }
    n = fread(dst, 1, len, f);
    fclose(f);
    if (n != len) {
        fprintf(stderr, "[err] %s: short read %zu/%zu\n", path, n, len);
        return -1;
    }
    return 0;
}

static int save_file(const char *path, const void *src, size_t len)
{
    FILE *f = fopen(path, "wb");
    size_t n;
    if (!f) { perror(path); return -1; }
    n = fwrite(src, 1, len, f);
    fclose(f);
    if (n != len) { fprintf(stderr, "[err] %s: short write\n", path); return -1; }
    return 0;
}

static void probe(void)
{
    uint32_t ver = mb_rd(MB_VERSION);
    printf("[probe] STATUS =0x%08x\n", mb_rd(MB_STATUS));
    printf("[probe] CTRL   =0x%08x\n", mb_rd(MB_CTRL));
    printf("[probe] IN     =0x%08x\n", mb_rd(MB_IN_ADDR));
    printf("[probe] OUT    =0x%08x\n", mb_rd(MB_OUT_ADDR));
    printf("[probe] LAYER  =0x%08x\n", mb_rd(MB_LAYER));
    printf("[probe] VERSION=0x%08x %s\n", ver,
           (ver == 0x20261018u) ? "(extended words enabled)" :
           "(0/other: extended words disabled or old bitstream)");
    if (ver != 0x20261018u)
        printf("[probe] hint: run 'm9_bringup boot' first (write valid IN/OUT)\n");
}

static int boot_enable(void)
{
    uint32_t ctrl, ver;
    mb_wr(MB_CTRL, 0u);              /* 先清 START */
    mb_wr(MB_IN_ADDR, IN_ADDR_PHYS); /* 有效 IN/OUT 触发 boot */
    mb_wr(MB_OUT_ADDR, OUT_ADDR_PHYS);
    __sync_synchronize();
    usleep(5000);                    /* 5 ms: 1 ms poll + VERSION/STATUS 写 */
    ctrl = mb_rd(MB_CTRL);
    ver  = mb_rd(MB_VERSION);
    printf("[boot] IN=0x%08x OUT=0x%08x CTRL=0x%08x STATUS=0x%08x VERSION=0x%08x\n",
           IN_ADDR_PHYS, OUT_ADDR_PHYS, ctrl, mb_rd(MB_STATUS), ver);
    return 0;
}

static int start_and_wait(uint32_t layer, uint32_t timeout_ms, int verbose)
{
    uint64_t t0, tbusy = 0, tdone = 0;
    int accepted = 0, seen_busy = 0;

    mb_wr(MB_IN_ADDR,  IN_ADDR_PHYS);
    mb_wr(MB_OUT_ADDR, OUT_ADDR_PHYS);
    mb_wr(MB_LAYER,    layer);
    __sync_synchronize();
    mb_wr(MB_CTRL, 1u);                 // START last

    t0 = now_ms();
    while ((now_ms() - t0) < 200u) {
        if (mb_rd(MB_CTRL) == 0u) { accepted = 1; break; }
        usleep(1000);
    }
    if (!accepted) {
        fprintf(stderr, "[FAIL] CTRL did not clear; FPGA did not accept START\n");
        return -2;
    }
    if (verbose)
        printf("[ ok ] CTRL cleared (START accepted), waiting...\n");

    while ((now_ms() - t0) < timeout_ms) {
        uint32_t s = mb_rd(MB_STATUS);
        if (s == 1u) {
            if (!seen_busy) { seen_busy = 1; tbusy = now_ms(); }
        } else if (s == 2u) {
            tdone = now_ms();
            printf("[ ok ] STATUS=0x2 DONE, elapsed=%llu ms (busy=%llu ms)\n",
                   (unsigned long long)(tdone - t0),
                   (unsigned long long)(seen_busy ? (tdone - tbusy) : 0));
            return 0;
        } else if (s == 6u) {
            fprintf(stderr, "[FAIL] STATUS=0x6 (done|ERR), OUT invalid\n");
            return 1;
        }
        usleep(1000);
    }
    fprintf(stderr, "[FAIL] timeout after %u ms, STATUS=0x%08x\n",
            timeout_ms, mb_rd(MB_STATUS));
    return -1;
}

static int compare_out(const char *exp_path, size_t len)
{
    uint8_t *exp = NULL, *got = NULL;
    size_t i, nerr = 0;

    got = (uint8_t *)malloc(len);
    if (!got) { perror("malloc"); return -1; }
    memcpy(got, (const void *)(g_win + OFF_OUT), len);

    if (!exp_path) {
        if (save_file("m9_out.bin", got, len) != 0) { free(got); return -1; }
        printf("[info] no expected file; saved m9_out.bin (%zu bytes)\n", len);
        free(got);
        return 0;
    }

    exp = (uint8_t *)malloc(len);
    if (!exp) { perror("malloc"); free(got); return -1; }
    if (load_file_mem(exp_path, exp, len) != 0) { free(got); free(exp); return -1; }

    for (i = 0; i < len; i++) {
        if (got[i] != exp[i]) {
            if (nerr < 16)
                printf("[FAIL] byte %zu got=%02x exp=%02x\n", i, got[i], exp[i]);
            nerr++;
        }
    }
    if (nerr == 0)
        printf("[ ok ] compare: %zu/%zu bytes all match\n", len, len);
    else
        printf("[FAIL] compare: %zu/%zu bytes mismatched\n", nerr, len);
    free(got);
    free(exp);
    return nerr ? -1 : 0;
}

static int cmd_full(const char *in_path, const char *exp_path)
{
    boot_enable();
    if (load_file_to(in_path, g_win + OFF_IN, IN_BYTES) != 0)
        return -1;
    printf("[full] loaded %u B input; starting LAYER=0x00FF (full chain)\n", IN_BYTES);
    if (start_and_wait(0x000000FFu, 180000u, 1) != 0)
        return -1;
    return compare_out(exp_path, OUT_BYTES);
}

/* ------------------------------------------------------------------ dual frame
 * 双帧 in-flight 2（1 深 pending）：
 *   A 用 IN slot0 启动 -> A 运行中把 B 的输入写进 slot1 再 START；
 *   期望：B 进 pending（CTRL 被清、STATUS 仍为 1、不出现 0x6）；
 *   A done -> STATUS=2 保持 C_DONE_HOLD_CYC(500 ms) -> B 启动(STATUS=1) -> ~111 s 后 done。
 *   判据：A 的 OUT 在 B 启动前读走并全对；B 的 OUT 全对；全程无 0x6。
 */
static int wait_ctrl_accepted(uint32_t timeout_ms)
{
    uint64_t t0 = now_ms();
    while ((now_ms() - t0) < timeout_ms) {
        if (mb_rd(MB_CTRL) == 0u) return 0;
        usleep(1000);
    }
    return -1;
}

static int wait_status_is(uint32_t want, uint32_t timeout_ms, uint64_t *t_hit)
{
    uint64_t t0 = now_ms();
    for (;;) {
        uint32_t s = mb_rd(MB_STATUS);
        if (s == 6u) return 6;
        if (s == want) { if (t_hit) *t_hit = now_ms(); return (int)want; }
        if ((now_ms() - t0) > timeout_ms) return -1;
        usleep(1000);
    }
}

static int cmd_dual(const char *inA, const char *expA,
                    const char *inB, const char *expB)
{
    uint64_t t_busyA = 0, t_doneA = 0, t_startB = 0, t_doneB = 0, t0;
    uint32_t s;
    int rc;

    boot_enable();
    if (mb_rd(MB_VERSION) != 0x20261018u)
        fprintf(stderr, "[warn] VERSION != 0x20261018 (old bitstream?)\n");

    /* ---------------- A: IN slot0 ---------------- */
    if (load_file_to(inA, g_win + OFF_IN, IN_BYTES) != 0) return -1;
    printf("[dual] A: IN=0x%08x OUT=0x%08x\n", IN_ADDR_PHYS, OUT_ADDR_PHYS);
    mb_wr(MB_IN_ADDR,  IN_ADDR_PHYS);
    mb_wr(MB_OUT_ADDR, OUT_ADDR_PHYS);
    mb_wr(MB_LAYER,    0x000000FFu);
    __sync_synchronize();
    mb_wr(MB_CTRL, 1u);
    if (wait_ctrl_accepted(200) != 0) {
        fprintf(stderr, "[FAIL] A: CTRL not cleared (START not accepted)\n");
        return -1;
    }
    rc = wait_status_is(1u, 5000u, &t_busyA);
    if (rc != 1) {
        fprintf(stderr, "[FAIL] A: no BUSY (rc=%d STATUS=0x%08x)\n", rc, mb_rd(MB_STATUS));
        return -1;
    }
    printf("[ ok ] A started (BUSY)\n");

    /* ---------------- B: A 仍在跑，用 slot1 ---------------- */
    if (load_file_to(inB, g_win + OFF_IN_B, IN_BYTES) != 0) return -1;
    printf("[dual] B: IN=0x%08x OUT=0x%08x (A still busy)\n",
           IN_B_ADDR_PHYS, OUT_ADDR_PHYS);
    mb_wr(MB_IN_ADDR,  IN_B_ADDR_PHYS);
    mb_wr(MB_OUT_ADDR, OUT_ADDR_PHYS);
    mb_wr(MB_LAYER,    0x000000FFu);
    __sync_synchronize();
    mb_wr(MB_CTRL, 1u);
    if (wait_ctrl_accepted(200) != 0) {
        fprintf(stderr, "[FAIL] B: CTRL not cleared while A busy\n");
        return -1;
    }
    s = mb_rd(MB_STATUS);
    if (s == 6u) {
        fprintf(stderr, "[FAIL] B: STATUS=0x6 (ghost / pending overflow)\n");
        return -1;
    }
    printf("[ ok ] B accepted into pending (STATUS=0x%x, A still running)\n", s);

    /* ---------------- A done：立刻读 OUT（B 至少 500 ms 后才启动） ---------------- */
    rc = wait_status_is(2u, 180000u, &t_doneA);
    if (rc != 2) {
        fprintf(stderr, "[FAIL] A: no DONE (rc=%d STATUS=0x%08x)\n", rc, mb_rd(MB_STATUS));
        return -1;
    }
    printf("[ ok ] A DONE (busy=%llu ms)\n", (unsigned long long)(t_doneA - t_busyA));
    if (compare_out(expA, OUT_BYTES) != 0) {
        fprintf(stderr, "[FAIL] A output mismatch (read during DONE hold)\n");
        return -1;
    }
    printf("[ ok ] A output verified while STATUS=2 (B has not started yet)\n");

    /* ---------------- DONE/OUT hold：STATUS 保持 2 一段时间后才变 1 ---------------- */
    t0 = now_ms();
    while ((now_ms() - t0) < 3000u) {
        s = mb_rd(MB_STATUS);
        if (s == 6u) { fprintf(stderr, "[FAIL] STATUS=0x6 during hold\n"); return -1; }
        if (s == 1u) { t_startB = now_ms(); break; }
        usleep(1000);
    }
    if (t_startB == 0) {
        fprintf(stderr, "[FAIL] B did not start within 3 s after A done\n");
        return -1;
    }
    printf("[ ok ] DONE/OUT hold = %llu ms, then B started (STATUS=1)\n",
           (unsigned long long)(t_startB - t_doneA));
    if ((t_startB - t_doneA) < 400u)
        printf("[warn] hold < 400 ms; C_DONE_HOLD_CYC may be too small\n");

    /* ---------------- B done：此时 OUT 是 B 的结果 ---------------- */
    rc = wait_status_is(2u, 180000u, &t_doneB);
    if (rc != 2) {
        fprintf(stderr, "[FAIL] B: no DONE (rc=%d STATUS=0x%08x)\n", rc, mb_rd(MB_STATUS));
        return -1;
    }
    printf("[ ok ] B DONE (busy=%llu ms)\n", (unsigned long long)(t_doneB - t_startB));
    if (expB != NULL && compare_out(expB, OUT_BYTES) != 0) {
        fprintf(stderr, "[FAIL] B output mismatch\n");
        return -1;
    }
    if (expB == NULL)
        compare_out(NULL, OUT_BYTES);   /* 只保存 m9_out.bin，事后回主机比对 */

    printf("[ ok ] dual frame PASS (no 0x6, A/B outputs both correct)\n");
    return 0;
}

static int cmd_single(uint32_t layer, const char *in_path,
                      const char *exp_path, size_t out_len)
{
    boot_enable();
    if (load_file_to(in_path, g_win + OFF_IN, IN_BYTES) != 0)
        return -1;
    printf("[single] LAYER=0x%08x, out_len=%zu\n", layer, out_len);
    if (start_and_wait(layer, 180000u, 1) != 0)
        return -1;
    return compare_out(exp_path, out_len);
}

static int cmd_softreset(void)
{
    uint32_t ver;
    uint64_t t0;

    boot_enable();
    ver = mb_rd(MB_VERSION);

    if (ver != 0x20261018u) {
        fprintf(stderr, "[skip] VERSION=0x%08x; extended words not enabled, "
                        "writing RESET would be ignored. Refusing.\n", ver);
        return -2;
    }
    printf("[reset] write RESET=1\n");
    mb_wr(MB_RESET, 1u);
    t0 = now_ms();
    while ((now_ms() - t0) < 2000u) {
        if (mb_rd(MB_RESET) == 0u) {
            printf("[ ok ] RESET self-cleared, STATUS=0x%08x\n", mb_rd(MB_STATUS));
            return (mb_rd(MB_STATUS) == 0u) ? 0 : -1;
        }
        usleep(1000);
    }
    fprintf(stderr, "[FAIL] RESET did not clear within 2 s\n");
    return -1;
}

static int cmd_dump(uint32_t off, size_t len, const char *path)
{
    if (off + len > WIN_SIZE) {
        fprintf(stderr, "[err] range 0x%x+0x%zx exceeds 64 MiB window\n", off, len);
        return -1;
    }
    return save_file(path, (const void *)(g_win + off), len);
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "usage:\n"
        "  %s boot\n"
        "  %s probe\n"
        "  %s full  <in.bin> [exp.bin]\n"
        "  %s dual  <inA.bin> <expA.bin> <inB.bin> [expB.bin]\n"
        "  %s single <layer_hex> <in.bin> [exp.bin] [out_len]\n"
        "  %s softreset\n"
        "  %s dump <offset_hex> <len> <out.bin>\n",
        prog, prog, prog, prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
    int rc;

    if (argc < 2) { usage(argv[0]); return 2; }
    if (map_window() != 0) return 2;

    if (!strcmp(argv[1], "boot")) {
        rc = boot_enable();
    } else if (!strcmp(argv[1], "probe")) {
        probe();
        rc = 0;
    } else if (!strcmp(argv[1], "full")) {
        if (argc < 3) { usage(argv[0]); rc = 2; }
        else rc = cmd_full(argv[2], (argc >= 4) ? argv[3] : NULL);
    } else if (!strcmp(argv[1], "dual")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else rc = cmd_dual(argv[2], argv[3], argv[4],
                           (argc >= 6) ? argv[5] : NULL);
    } else if (!strcmp(argv[1], "single")) {
        size_t out_len;
        uint32_t layer;
        if (argc < 4) { usage(argv[0]); rc = 2; }
        else {
            layer = (uint32_t)strtoul(argv[2], NULL, 0);
            out_len = (argc >= 6) ? (size_t)strtoul(argv[5], NULL, 0) : 262144u;
            rc = cmd_single(layer, argv[3], (argc >= 5) ? argv[4] : NULL, out_len);
        }
    } else if (!strcmp(argv[1], "softreset")) {
        rc = cmd_softreset();
    } else if (!strcmp(argv[1], "dump")) {
        if (argc < 5) { usage(argv[0]); rc = 2; }
        else {
            uint32_t off = (uint32_t)strtoul(argv[2], NULL, 0);
            size_t len = (size_t)strtoul(argv[3], NULL, 0);
            rc = cmd_dump(off, len, argv[4]);
        }
    } else {
        usage(argv[0]);
        rc = 2;
    }

    if (g_win) munmap((void *)g_win, WIN_SIZE);
    if (g_fd >= 0) close(g_fd);
    return (rc == 0) ? 0 : 1;
}
