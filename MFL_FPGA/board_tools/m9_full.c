/* m9_full.c -- freestanding aarch64 Linux helper for the Kosmo2 M9 mailbox.
 *
 * No libc: raw syscalls only, talks to /dev/uio0 (64 MiB @ phys 0x300000)
 * through mmap. Use this when /dev/mem write() is refused (dd -> Bad address).
 *
 * Build (Windows host, PDS EDK bare-metal gcc -- same recipe as mbox_gate_test):
 *   D:\PDS_2025.2\PDS\pango\PDS_2025.2-ads\edk\toolchain\gnu\aarch64\aarch64-none\bin\
 *     aarch64-none-elf-gcc -nostdlib -static -ffreestanding -O2 -Wl,-e,_start \
 *       -o m9_full m9_full.c
 *
 * On board:
 *   ./m9_full probe                                  # read 8 mailbox words
 *   ./m9_full boot                                   # write valid IN/OUT, print VERSION/STATUS
 *   ./m9_full full /tmp/m9_in.bin /tmp/m9_exp.bin    # full chain + byte compare
 *   ./m9_full full /tmp/m9_in.bin                    # full chain, dump OUT to /tmp/m9_out.bin
 *   ./m9_full dual /tmp/m9_in.bin /tmp/m9_exp.bin /tmp/m9_in_b.bin /tmp/m9_exp_b.bin
 *                                                    # 双帧 in-flight 2 / 1 深 pending + 两帧各自对拍
 *   ./m9_full dump 0x170000 46080 /tmp/m9_out.bin    # window offset -> file
 *   ./m9_full softreset                              # RESET=1, wait self-clear
 *
 * Timing note: nanosleep returns immediately on this kernel/toolchain combo,
 * so every wait here is driven by clock_gettime(CLOCK_MONOTONIC) instead.
 * The OUT buffer is pre-filled with 0xA5 so a stale result from an earlier
 * frame can never be mistaken for a pass.
 */

typedef unsigned long  u64;
typedef unsigned int   u32;
typedef unsigned char  u8;

static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x3 asm("x3") = d;
    register long x4 asm("x4") = e;
    register long x5 asm("x5") = f;
    asm volatile("svc 0" : "+r"(x0)
                 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                 : "memory");
    return x0;
}

#define SYS_openat        56
#define SYS_close         57
#define SYS_read          63
#define SYS_write         64
#define SYS_exit_group    94
#define SYS_clock_gettime 113
#define SYS_mmap          222

#define CLOCK_MONOTONIC 1

#define O_RDONLY 0
#define O_RDWR   2
#define O_CREAT  0100
#define O_TRUNC  01000
#define O_WRONLY 1

#define WIN_SIZE (64UL << 20)
#define MB_OFF   0x1000
#define IN_OFF   0x2000
#define OUT_OFF  0x170000

#define IN_LEN   1474560UL
#define OUT_LEN  46080UL

#define IN_ADDR  0x00302000u
#define OUT_ADDR 0x00470000u
#define VERSION_EXP 0x20261018u

/* 双帧（in-flight 2）: B 帧走 IN slot1，与 ARM 驱动 slot1 一致 */
#define IN_B_ADDR 0x01500000u
#define IN_B_OFF  (IN_B_ADDR - 0x00300000u)   /* 0x1200000 */

#define T_ACCEPT_MS 5000L     /* 等 STATUS 变 1 */
#define T_DONE_MS   300000L   /* 等 STATUS 变 2 */
#define T_BOOT_MS   50L       /* 等 VERSION */

/* ---------------- 输出 ---------------- */
static void put_s(const char *s)
{
    long n = 0;
    while (s[n]) n++;
    sys6(SYS_write, 1, (long)s, n, 0, 0, 0);
}
static void put_c(char c) { sys6(SYS_write, 1, (long)&c, 1, 0, 0, 0); }
static void put_hex(u64 v, int digits)
{
    char b[20];
    int i;
    b[0] = '0'; b[1] = 'x';
    for (i = 0; i < digits; i++) {
        int d = (int)((v >> ((digits - 1 - i) * 4)) & 0xF);
        b[2 + i] = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
    }
    sys6(SYS_write, 1, (long)b, 2 + digits, 0, 0, 0);
}
static void put_dec(u64 v)
{
    char b[24];
    int i = 24;
    if (v == 0) { put_c('0'); return; }
    while (v) { b[--i] = (char)('0' + (v % 10u)); v /= 10u; }
    sys6(SYS_write, 1, (long)&b[i], 24 - i, 0, 0, 0);
}

/* ---------------- 时间（不依赖 nanosleep） ---------------- */
struct ts_t { long sec; long nsec; };

static void now_ms(long *ms)
{
    struct ts_t t;
    sys6(SYS_clock_gettime, CLOCK_MONOTONIC, (long)&t, 0, 0, 0, 0);
    *ms = t.sec * 1000L + t.nsec / 1000000L;
}
static void wait_ms(long ms)
{
    long t0, t;
    now_ms(&t0);
    do { now_ms(&t); } while ((t - t0) < ms);
}

/* ---------------- 工具 ---------------- */
void *memset(void *d, int c, u64 n)
{ u8 *p = d; while (n--) *p++ = (u8)c; return d; }
void *memcpy(void *d, const void *s, u64 n)
{ u8 *p = d; const u8 *q = s; while (n--) *p++ = *q++; return d; }

static int str_eq(const char *a, const char *b)
{
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return (*a == *b);
}
static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static u64 parse_num(const char *s)
{
    u64 v = 0;
    int base = 10;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    while (*s) {
        int d = hexval(*s);
        if (d < 0 || d >= base) break;
        v = v * (u64)base + (u64)d;
        s++;
    }
    return v;
}

static long open_ro(const char *p)  { return sys6(SYS_openat, -100, (long)p, O_RDONLY, 0, 0, 0); }
static long open_rw(const char *p)  { return sys6(SYS_openat, -100, (long)p, O_RDWR, 0, 0, 0); }
static long open_new(const char *p)
{ return sys6(SYS_openat, -100, (long)p, O_WRONLY | O_CREAT | O_TRUNC, 0644, 0, 0); }

/* ---------------- 窗口访问 ---------------- */
static volatile u8  *win;
static volatile u32 *mb;

static void wr_mb(int idx, u32 v)
{
    mb[idx] = v;
    asm volatile("dsb sy" ::: "memory");
}

static void dev_write(const volatile u8 *dst, const u8 *src, u64 n)
{
    volatile u64 *d = (volatile u64 *)dst;
    const u64 *s = (const u64 *)src;
    u64 i, w = n >> 3;
    for (i = 0; i < w; i++) d[i] = s[i];
    for (i = w << 3; i < n; i++) ((volatile u8 *)d)[i] = src[i];
    asm volatile("dsb sy" ::: "memory");
}
static void dev_read(u8 *dst, const volatile u8 *src, u64 n)
{
    const volatile u64 *s = (const volatile u64 *)src;
    u64 *d = (u64 *)dst;
    u64 i, w = n >> 3;
    for (i = 0; i < w; i++) d[i] = s[i];
    for (i = w << 3; i < n; i++) dst[i] = ((const volatile u8 *)s)[i];
}
static void dev_fill(const volatile u8 *dst, u8 v, u64 n)
{
    volatile u64 *d = (volatile u64 *)dst;
    u64 pat = 0x0101010101010101ULL * (u64)v;
    u64 i, w = n >> 3;
    for (i = 0; i < w; i++) d[i] = pat;
    for (i = w << 3; i < n; i++) ((volatile u8 *)d)[i] = v;
    asm volatile("dsb sy" ::: "memory");
}

static int write_file(const char *p, const u8 *b, u64 n)
{
    long fd = open_new(p);
    if (fd < 0) return -1;
    while (n) {
        long k = sys6(SYS_write, fd, (long)b, (long)n, 0, 0, 0);
        if (k <= 0) { sys6(SYS_close, fd, 0, 0, 0, 0, 0); return -1; }
        b += k;
        n -= (u64)k;
    }
    sys6(SYS_close, fd, 0, 0, 0, 0, 0);
    return 0;
}

/* ---------------- 缓存 ---------------- */
static u8 inbuf[IN_LEN];
static u8 outbuf[OUT_LEN];

/* ---------------- 命令 ---------------- */
static void cmd_probe(void)
{
    static const char *nm[8] = {
        "IN    ", "OUT   ", "SLOT  ", "CTRL  ",
        "STATUS", "LAYER ", "VERSION", "RESET "
    };
    int i;
    for (i = 0; i < 8; i++) {
        put_s(nm[i]);
        put_s(" (+0x");
        put_hex((u64)(i * 4), 2);
        put_s(") = ");
        put_hex(mb[i], 8);
        put_s("\n");
    }
}

static void cmd_boot(void)
{
    long t0, t;
    long *p0 = &t0;
    long *pt = &t;
    now_ms(p0);
    wr_mb(3, 0);
    wr_mb(0, IN_ADDR);
    wr_mb(1, OUT_ADDR);
    while (1) {
        now_ms(pt);
        if (mb[6] == VERSION_EXP) break;
        if ((*pt - *p0) > T_BOOT_MS) break;
        wait_ms(1);
    }
    put_s("boot: IN=");   put_hex(mb[0], 8);
    put_s(" OUT=");       put_hex(mb[1], 8);
    put_s("\nboot: STATUS="); put_hex(mb[4], 8);
    put_s(" CTRL=");      put_hex(mb[3], 8);
    put_s(" VERSION=");   put_hex(mb[6], 8);
    put_s("\n");
    if (mb[6] != VERSION_EXP) {
        put_s("WARN: VERSION != 0x20261018 (old bitstream / gate still closed)\n");
    }
}

static int cmd_full(const char *inpath, const char *exppath, const char *outpath)
{
    long fd, k, t0, now, last_dot;
    u64 done = 0, i;
    u32 st, ver;

    /* 0) 上一帧还在跑就不要发新帧（会把别人的结果当成自己的） */
    if (mb[4] == 1u) {
        put_s("ABORT: STATUS=1 (previous frame still running).\n");
        put_s("       wait for it to finish, or run: m9_full softreset\n");
        return 1;
    }

    /* 1) 读输入文件 */
    fd = open_ro(inpath);
    if (fd < 0) { put_s("open input FAIL\n"); return 1; }
    while (done < IN_LEN) {
        k = sys6(SYS_read, fd, (long)(inbuf + done), (long)(IN_LEN - done), 0, 0, 0);
        if (k <= 0) break;
        done += (u64)k;
    }
    sys6(SYS_close, fd, 0, 0, 0, 0, 0);
    if (done != IN_LEN) {
        put_s("input size bad: got "); put_dec(done);
        put_s(" expected "); put_dec(IN_LEN); put_s("\n");
        return 1;
    }
    put_s("input loaded: "); put_dec(done); put_s(" bytes\n");

    /* 2) 灌进 IN_BUF (phys 0x302000) */
    dev_write(win + IN_OFF, inbuf, IN_LEN);
    put_s("IN buffer written\n");

    /* 3) 开锁 + 等 boot */
    now_ms(&t0);
    wr_mb(3, 0);
    wr_mb(0, IN_ADDR);
    wr_mb(1, OUT_ADDR);
    while (1) {
        now_ms(&now);
        if (mb[6] == VERSION_EXP) break;
        if ((now - t0) > T_BOOT_MS) break;
        wait_ms(1);
    }
    ver = mb[6];
    put_s("VERSION="); put_hex(ver, 8);
    put_s(" STATUS="); put_hex(mb[4], 8); put_s("\n");
    if (ver != VERSION_EXP) {
        put_s("ABORT: gate did not open (VERSION mismatch)\n");
        return 1;
    }

    /* 4) OUT 先填 0xA5：防止把上一帧遗留的结果当成本帧结果 */
    dev_fill(win + OUT_OFF, 0xA5, OUT_LEN);

    /* 5) LAYER=0xFF 全链, 再 START */
    wr_mb(5, 0x000000FFu);
    now_ms(&t0);
    wr_mb(3, 1);
    put_s("started, waiting CTRL cleared, then STATUS 1 -> 2\n");

    /* 6) 等受理：CTRL 被 FPGA 清 0（与 m9_bringup 同口径）。
     *    不能拿 STATUS==2 当判据 —— 那是上一帧的遗留值。 */
    while (1) {
        now_ms(&now);
        if ((mb[3] & 1u) == 0u) break;
        if ((now - t0) > 1000L) {
            put_s("TIMEOUT: CTRL not cleared in 1000 ms (START not accepted)\n");
            put_s("STATUS=");  put_hex(mb[4], 8);
            put_s(" CTRL=");   put_hex(mb[3], 8); put_s("\n");
            return 1;
        }
        wait_ms(1);
    }
    put_s("accepted: CTRL=0 at "); put_dec((u64)(now - t0)); put_s(" ms\n");

    /* 7) 适配器受理后先清 CTRL 再写 STATUS=1；给它 2 ms 再读，
     *    躲开"旧 STATUS=2 还没被覆盖"的那几微秒窗口。 */
    wait_ms(2);
    st = mb[4];
    if (st == 1u) {
        put_s("running: STATUS=1\n");
        /* 8) 等完成（STATUS=2 或 6） */
        last_dot = now;
        while (1) {
            now_ms(&now);
            st = mb[4];
            if (st == 2u || st == 6u) break;
            if ((now - t0) > T_DONE_MS) break;
            if ((now - last_dot) >= 10000L) { put_c('.'); last_dot = now; }
            wait_ms(1);
        }
    } else {
        /* 极快的帧可能已经到 2；直接按完成处理 */
        put_s("note: STATUS already "); put_hex(st, 8);
        put_s(" right after accept\n");
    }

    put_s("\nSTATUS="); put_hex(st, 8);
    put_s("  frame time = "); put_dec((u64)(now - t0)); put_s(" ms\n");
    if (st == 6u) { put_s("STATUS=6 (ERR): OUT is invalid, do not use\n"); return 1; }
    if (st != 2u) { put_s("TIMEOUT\n"); return 1; }

    /* 8) 读 OUT */
    dev_read(outbuf, win + OUT_OFF, OUT_LEN);
    put_s("OUT read: "); put_dec(OUT_LEN); put_s(" bytes\n");

    /* 9) 比对或落盘 */
    if (exppath) {
        u8 ebuf[4096];
        u64 off = 0, bad = 0;
        int shown = 0;
        fd = open_ro(exppath);
        if (fd < 0) { put_s("open exp FAIL\n"); return 1; }
        while (off < OUT_LEN) {
            u64 want = OUT_LEN - off;
            if (want > sizeof(ebuf)) want = sizeof(ebuf);
            k = sys6(SYS_read, fd, (long)ebuf, (long)want, 0, 0, 0);
            if (k <= 0) break;
            for (i = 0; i < (u64)k; i++) {
                if (ebuf[i] != outbuf[off + i]) {
                    bad++;
                    if (shown < 16) {
                        put_s("  mismatch @"); put_dec(off + i);
                        put_s(" got="); put_hex(outbuf[off + i], 2);
                        put_s(" exp="); put_hex(ebuf[i], 2);
                        put_s("\n");
                        shown++;
                    }
                }
            }
            off += (u64)k;
        }
        sys6(SYS_close, fd, 0, 0, 0, 0, 0);
        put_s("compared "); put_dec(off); put_s(" bytes, mismatches="); put_dec(bad); put_s("\n");
        if (off != OUT_LEN) { put_s("exp file shorter than 46080\n"); return 1; }
        if (bad == 0) { put_s("ALL MATCH\n"); return 0; }
        return 1;
    } else {
        const char *p = outpath ? outpath : "/tmp/m9_out.bin";
        if (write_file(p, outbuf, OUT_LEN) != 0) { put_s("write out FAIL\n"); return 1; }
        put_s("OUT dumped to "); put_s(p); put_s("\n");
        put_s("compare on board: busybox md5sum "); put_s(p); put_s("\n");
        return 0;
    }
}

/* =====================================================================
 * 双帧（in-flight 2 / 1 深 pending）
 *   A 用 IN slot0 启动 -> A 运行中把 B 输入写进 slot1 再 START
 *   期望：B 进 pending（CTRL 被清、STATUS 仍 1、无 0x6）
 *   A done -> STATUS=2 保持 C_DONE_HOLD_CYC(500ms) -> B 启动 -> ~111s 后 done
 *   判据：A 的 OUT 在 B 启动前读走且全对；B 的 OUT 全对；全程无 0x6
 * ===================================================================== */
static int wait_ctrl0(long tmo_ms)
{
    long t0, t;
    now_ms(&t0);
    for (;;) {
        if ((mb[3] & 1u) == 0u) return 0;
        now_ms(&t);
        if ((t - t0) > tmo_ms) return -1;
        wait_ms(1);
    }
}

static int wait_status(u32 want, long tmo_ms, long *t_hit)
{
    long t0, t;
    now_ms(&t0);
    for (;;) {
        u32 s = mb[4];
        if (s == 6u) return 6;
        if (s == want) { if (t_hit) now_ms(t_hit); return (int)want; }
        now_ms(&t);
        if ((t - t0) > tmo_ms) return -1;
        wait_ms(1);
    }
}

/* 读 <path> 的 IN_LEN 字节并灌到窗口偏移 off（slot0 / slot1） */
static int load_input(const char *path, u64 off)
{
    long fd, k;
    u64 done = 0;
    fd = open_ro(path);
    if (fd < 0) { put_s("open input FAIL: "); put_s(path); put_s("\n"); return -1; }
    while (done < IN_LEN) {
        k = sys6(SYS_read, fd, (long)(inbuf + done), (long)(IN_LEN - done), 0, 0, 0);
        if (k <= 0) break;
        done += (u64)k;
    }
    sys6(SYS_close, fd, 0, 0, 0, 0, 0);
    if (done != IN_LEN) {
        put_s("input size bad: "); put_dec(done); put_s(" / "); put_dec(IN_LEN); put_s("\n");
        return -1;
    }
    dev_write(win + off, inbuf, IN_LEN);
    put_s("input loaded: "); put_dec(done); put_s(" bytes -> phys ");
    put_hex(off + 0x00300000u, 8); put_s("\n");
    return 0;
}

/* 把 outbuf（当前 OUT 缓冲）与预期文件逐字节比较 */
static int cmp_out_buf(const char *exppath)
{
    u8 ebuf[4096];
    long fd, k;
    u64 off = 0, bad = 0;
    int shown = 0, i;
    fd = open_ro(exppath);
    if (fd < 0) { put_s("open exp FAIL: "); put_s(exppath); put_s("\n"); return -1; }
    while (off < OUT_LEN) {
        u64 want = OUT_LEN - off;
        if (want > sizeof(ebuf)) want = sizeof(ebuf);
        k = sys6(SYS_read, fd, (long)ebuf, (long)want, 0, 0, 0);
        if (k <= 0) break;
        for (i = 0; i < (int)k; i++) {
            if (ebuf[i] != outbuf[off + (u64)i]) {
                bad++;
                if (shown < 8) {
                    put_s("  mismatch @"); put_dec(off + (u64)i);
                    put_s(" got="); put_hex(outbuf[off + (u64)i], 2);
                    put_s(" exp="); put_hex(ebuf[i], 2); put_s("\n");
                    shown++;
                }
            }
        }
        off += (u64)k;
    }
    sys6(SYS_close, fd, 0, 0, 0, 0, 0);
    put_s("compared "); put_dec(off); put_s(" bytes, mismatches="); put_dec(bad); put_s("\n");
    if (off != OUT_LEN) { put_s("exp file shorter than 46080\n"); return -1; }
    if (bad) return -1;
    put_s("ALL MATCH\n");
    return 0;
}

static int cmd_dual(const char *inA, const char *expA,
                    const char *inB, const char *expB)
{
    long t0, t, t_busyA = 0, t_doneA = 0, t_startB = 0, t_doneB = 0;
    u32 s;
    int rc;

    if (mb[4] == 1u) {
        put_s("ABORT: STATUS=1 (previous frame still running)\n");
        return 1;
    }

    /* 0) 确保门已开（VERSION 是开锁标志） */
    if (mb[6] != VERSION_EXP) {
        wr_mb(3, 0); wr_mb(0, IN_ADDR); wr_mb(1, OUT_ADDR);
        now_ms(&t0);
        for (;;) {
            now_ms(&t);
            if (mb[6] == VERSION_EXP) break;
            if ((t - t0) > T_BOOT_MS) break;
            wait_ms(1);
        }
    }
    put_s("VERSION="); put_hex(mb[6], 8);
    put_s(" STATUS="); put_hex(mb[4], 8); put_s("\n");
    if (mb[6] != VERSION_EXP) { put_s("ABORT: gate did not open (VERSION mismatch)\n"); return 1; }

    /* 1) A: IN slot0 */
    put_s("-- A: IN=0x00302000 OUT=0x00470000 --\n");
    if (load_input(inA, IN_OFF) != 0) return 1;
    dev_fill(win + OUT_OFF, 0xA5, OUT_LEN);      /* 防"上一帧残留当结果" */
    wr_mb(0, IN_ADDR); wr_mb(1, OUT_ADDR); wr_mb(5, 0x000000FFu);
    wr_mb(3, 1);                                 /* START 最后 */
    if (wait_ctrl0(1000) != 0) { put_s("ABORT: A START not accepted (CTRL stuck)\n"); return 1; }
    rc = wait_status(1u, T_ACCEPT_MS, &t_busyA);
    if (rc != 1) { put_s("ABORT: A no BUSY (rc="); put_dec((u64)(long)rc); put_s(")\n"); return 1; }
    put_s("A running (STATUS=1)\n");

    /* 2) B: A 仍在跑，写 slot1 再 START -> 进 pending */
    put_s("-- B: IN=0x01500000 OUT=0x00470000 (A still busy) --\n");
    if (load_input(inB, IN_B_OFF) != 0) return 1;
    wr_mb(0, IN_B_ADDR); wr_mb(1, OUT_ADDR); wr_mb(5, 0x000000FFu);
    wr_mb(3, 1);
    if (wait_ctrl0(1000) != 0) { put_s("ABORT: B START not accepted while A busy\n"); return 1; }
    s = mb[4];
    if (s == 6u) { put_s("ABORT: B -> STATUS=6 (ghost / pending overflow)\n"); return 1; }
    put_s("B queued as pending, STATUS="); put_hex(s, 8); put_s("\n");

    /* 3) A done：趁 B 尚未启动，先读 OUT 比对 */
    rc = wait_status(2u, T_DONE_MS, &t_doneA);
    if (rc != 2) { put_s("ABORT: A no DONE (rc="); put_dec((u64)(long)rc); put_s(")\n"); return 1; }
    put_s("A DONE: busy="); put_dec((u64)(t_doneA - t_busyA)); put_s(" ms\n");
    dev_read(outbuf, win + OUT_OFF, OUT_LEN);
    if (cmp_out_buf(expA) != 0) { put_s("FAIL: A output mismatch\n"); return 1; }
    put_s("A output OK (read during STATUS=2, B not started yet)\n");

    /* 4) DONE/OUT hold：STATUS 应保持 2 一段时间后才变 1 */
    now_ms(&t0);
    for (;;) {
        s = mb[4];
        if (s == 6u) { put_s("FAIL: STATUS=6 during hold\n"); return 1; }
        if (s == 1u) { now_ms(&t_startB); break; }
        now_ms(&t);
        if ((t - t0) > 3000L) { put_s("FAIL: B did not start within 3 s\n"); return 1; }
        wait_ms(1);
    }
    put_s("hold="); put_dec((u64)(t_startB - t_doneA)); put_s(" ms -> B started (STATUS=1)\n");
    if ((t_startB - t_doneA) < 400L) put_s("WARN: hold < 400 ms (C_DONE_HOLD_CYC?)\n");

    /* 5) B done：此时 OUT 是 B 的结果 */
    rc = wait_status(2u, T_DONE_MS, &t_doneB);
    if (rc != 2) { put_s("ABORT: B no DONE (rc="); put_dec((u64)(long)rc); put_s(")\n"); return 1; }
    put_s("B DONE: busy="); put_dec((u64)(t_doneB - t_startB)); put_s(" ms\n");
    dev_read(outbuf, win + OUT_OFF, OUT_LEN);
    if (expB) {
        if (cmp_out_buf(expB) != 0) { put_s("FAIL: B output mismatch\n"); return 1; }
    } else {
        if (write_file("/tmp/m9_out.bin", outbuf, OUT_LEN) != 0) {
            put_s("write out FAIL\n"); return 1;
        }
        put_s("B OUT dumped to /tmp/m9_out.bin\n");
    }
    put_s("DUAL FRAME PASS (no 0x6, A/B outputs both correct)\n");
    return 0;
}

/* =====================================================================
 * export <N> <in.bin> <out_file> [timeout_s]
 *   逐层导出（V2）：LAYER=0x300|N，OUT 按 rev4 路由表指 scratch，
 *   导出 pre-ReLU/pre-Pool 输出后恢复 OUT=0x470000。
 *   路由表（doc/完整M9_top_上板Bring-up指南_50MHz.md §4.3.2）：
 *     N=0,1,2,7,8,9 -> scratch B 0xD00000 ; N=3,4,5,6 -> scratch A 0x500000
 * ===================================================================== */
static int cmd_dump(u64 off, u64 len, const char *out);   /* 前置声明：export 复用 */

static int cmd_export(int n, const char *inpath, const char *outfile, long timeout_s)
{
    static const u32 OUTP[10] = {
        0x00D00000u, 0x00D00000u, 0x00D00000u, 0x00500000u, 0x00500000u,
        0x00500000u, 0x00500000u, 0x00D00000u, 0x00D00000u, 0x00D00000u
    };
    static const u32 LEN[10] = {
        7864320u, 7864320u, 3932160u, 3932160u, 1966080u,
        1966080u, 737280u, 737280u, 184320u, 184320u
    };
    u32 outp = OUTP[n], len = LEN[n];
    u64 off = outp - 0x00300000u;
    long t0, t, t_busy = 0;
    int rc;

    if (mb[4] == 1u) {
        put_s("ABORT: STATUS=1 (previous frame still running)\n");
        return 1;
    }
    if (load_input(inpath, IN_OFF) != 0) return 1;

    /* 门（VERSION） */
    if (mb[6] != VERSION_EXP) {
        wr_mb(3, 0); wr_mb(0, IN_ADDR); wr_mb(1, OUT_ADDR);
        now_ms(&t0);
        for (;;) {
            now_ms(&t);
            if (mb[6] == VERSION_EXP) break;
            if ((t - t0) > T_BOOT_MS) break;
            wait_ms(1);
        }
    }
    put_s("VERSION="); put_hex(mb[6], 8);
    put_s(" STATUS="); put_hex(mb[4], 8); put_s("\n");
    if (mb[6] != VERSION_EXP) { put_s("ABORT: gate did not open\n"); return 1; }

    /* OUT 区先填 0xA5：防上帧残留冒充结果 */
    dev_fill(win + off, 0xA5, len);
    wr_mb(0, IN_ADDR);
    wr_mb(1, outp);
    wr_mb(5, 0x00000300u | (u32)n);
    wr_mb(3, 1);
    if (wait_ctrl0(1000) != 0) { put_s("ABORT: START not accepted\n"); return 1; }
    rc = wait_status(1u, T_ACCEPT_MS, &t_busy);
    if (rc != 1) { put_s("ABORT: no BUSY\n"); return 1; }
    rc = wait_status(2u, timeout_s * 1000L, &t);
    if (rc == 6u) { put_s("FAIL: STATUS=6 (ERR)\n"); return 1; }
    if (rc != 2) { put_s("ABORT: no DONE (rc="); put_dec((u64)(long)rc); put_s(")\n"); return 1; }
    put_s("L"); put_dec((u64)n);
    put_s(" DONE busy="); put_dec((u64)(t - t_busy)); put_s(" ms\n");

    if (cmd_dump(off, len, outfile) != 0) return 1;
    wr_mb(1, OUT_ADDR);                     /* 恢复 final OUT */
    put_s("OUT restored to 0x00470000\n");
    return 0;
}

static int cmd_dump(u64 off, u64 len, const char *out)
{
    long fd;
    u8 tmp[1024];
    u64 p = 0;
    if (off + len > WIN_SIZE) { put_s("range beyond 64 MiB window\n"); return 1; }
    fd = open_new(out);
    if (fd < 0) { put_s("open out FAIL\n"); return 1; }
    while (p < len) {
        u64 k = len - p, i;
        if (k > sizeof(tmp)) k = sizeof(tmp);
        for (i = 0; i < k; i++) tmp[i] = win[off + p + i];
        if (sys6(SYS_write, fd, (long)tmp, (long)k, 0, 0, 0) != (long)k) {
            put_s("write FAIL\n"); sys6(SYS_close, fd, 0, 0, 0, 0, 0); return 1;
        }
        p += k;
    }
    sys6(SYS_close, fd, 0, 0, 0, 0, 0);
    put_s("dumped "); put_dec(len); put_s(" bytes -> "); put_s(out); put_s("\n");
    return 0;
}

static int cmd_softreset(void)
{
    long t0, t;
    if (mb[6] != VERSION_EXP) {
        put_s("VERSION != 0x20261018, refuse to write RESET\n");
        return 1;
    }
    now_ms(&t0);
    wr_mb(7, 1);
    while (1) {
        now_ms(&t);
        if (mb[7] == 0u) break;
        if ((t - t0) > 1000L) break;
        wait_ms(1);
    }
    put_s("RESET=");  put_hex(mb[7], 8);
    put_s(" STATUS="); put_hex(mb[4], 8);
    put_s(" CTRL=");  put_hex(mb[3], 8);
    put_s("  ("); put_dec((u64)(t - t0)); put_s(" ms)\n");
    return (mb[7] == 0u) ? 0 : 1;
}

/* ---------------- 入口 ---------------- */
void _start_c(u64 *sp);
__asm__(
    ".text\n"
    ".global _start\n"
    "_start:\n"
    "  mov x0, sp\n"
    "  b _start_c\n"
    ".size _start, .-_start\n"
);

void _start_c(u64 *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);
    long fd;
    int rc = 1;

    fd = open_rw("/dev/uio0");
    if (fd < 0) { put_s("open /dev/uio0 FAIL (need root)\n"); sys6(SYS_exit_group, 1, 0, 0, 0, 0, 0); }

    win = (volatile u8 *)sys6(SYS_mmap, 0, (long)WIN_SIZE, 3 /*RW*/, 1 /*SHARED*/, fd, 0);
    if ((long)win < 0 && (long)win > -4096) {
        put_s("mmap 64 MiB FAIL\n");
        sys6(SYS_exit_group, 1, 0, 0, 0, 0, 0);
    }
    mb = (volatile u32 *)(win + MB_OFF);

    if (argc < 2) {
        put_s("usage:\n");
        put_s("  m9_full probe\n");
        put_s("  m9_full boot\n");
        put_s("  m9_full full <in.bin> [exp.bin] [out.bin]\n");
        put_s("  m9_full dual <inA.bin> <expA.bin> <inB.bin> [expB.bin]\n");
        put_s("  m9_full export <N> <in.bin> <out.bin> [timeout_s]\n");
        put_s("  m9_full dump <off_hex> <len> <out.bin>\n");
        put_s("  m9_full softreset\n");
        sys6(SYS_exit_group, 2, 0, 0, 0, 0, 0);
    }

    if (str_eq(argv[1], "probe")) {
        cmd_probe();
        rc = 0;
    } else if (str_eq(argv[1], "boot")) {
        cmd_boot();
        rc = 0;
    } else if (str_eq(argv[1], "full")) {
        if (argc < 3) { put_s("full needs <in.bin>\n"); rc = 2; }
        else rc = cmd_full(argv[2],
                           (argc > 3) ? argv[3] : 0,
                           (argc > 4) ? argv[4] : 0);
    } else if (str_eq(argv[1], "dual")) {
        if (argc < 5) { put_s("dual needs <inA> <expA> <inB> [expB]\n"); rc = 2; }
        else rc = cmd_dual(argv[2], argv[3], argv[4],
                           (argc > 5) ? argv[5] : 0);
    } else if (str_eq(argv[1], "export")) {
        if (argc < 5) { put_s("export needs <N> <in.bin> <out.bin> [timeout_s]\n"); rc = 2; }
        else {
            int n = (int)parse_num(argv[2]);
            long tmo = (argc > 5) ? (long)parse_num(argv[5]) : 120L;
            if (n < 0 || n > 9) { put_s("N must be 0..9\n"); rc = 2; }
            else rc = cmd_export(n, argv[3], argv[4], tmo);
        }
    } else if (str_eq(argv[1], "dump")) {
        if (argc < 5) { put_s("dump needs <off_hex> <len> <out.bin>\n"); rc = 2; }
        else rc = cmd_dump(parse_num(argv[2]), parse_num(argv[3]), argv[4]);
    } else if (str_eq(argv[1], "softreset")) {
        rc = cmd_softreset();
    } else {
        put_s("unknown command\n");
        rc = 2;
    }

    sys6(SYS_exit_group, rc, 0, 0, 0, 0, 0);
    for (;;) { }
}
