/* mbox_gate_test.c -- freestanding aarch64 Linux binary (no libc)
 * Verifies M9 mailbox boot gate through /dev/uio0 (non-cacheable mmap):
 *   1) dump 8 mailbox words (expect u-boot residue, VERSION != 0x20261018)
 *   2) IN=0x302000, OUT=0x470000, CTRL=0 (valid IN/OUT triggers boot; no magic)
 *   3) wait ~200 ms, dump STATUS/VERSION/CTRL again
 * Build (host, EDK bare-metal gcc):
 *   aarch64-none-elf-gcc-10.2.1 -nostdlib -static -ffreestanding -O2 \
 *     -Wl,-e,_start -o mbox_gate_test mbox_gate_test.c
 */
typedef unsigned long u64;
typedef unsigned int u32;

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
#define SYS_openat 56
#define SYS_write  64
#define SYS_mmap   222
#define SYS_nanosleep 101
#define SYS_exit_group 94

static void sys_exit(int code) { sys6(SYS_exit_group, code, 0, 0, 0, 0, 0); }
static long sys_write(int fd, const void *buf, long len)
{ return sys6(SYS_write, fd, (long)buf, len, 0, 0, 0); }

static void puts_(const char *s)
{
    long n = 0;
    while (s[n]) n++;
    sys_write(1, s, n);
}

static void puthex(u64 v)
{
    char buf[20];
    int i;
    buf[0] = '0'; buf[1] = 'x';
    for (i = 0; i < 8; i++) {
        int d = (int)((v >> ((7 - i) * 4)) & 0xF);
        buf[2 + i] = d < 10 ? '0' + d : 'a' + d - 10;
    }
    buf[10] = '\n';
    sys_write(1, buf, 11);
}

/* memset/memcpy in case gcc synthesizes calls (freestanding) */
void *memset(void *d, int c, unsigned long n)
{ unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, unsigned long n)
{ unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

#define PROT_RW 3
#define MAP_SHARED 1
#define WIN_SIZE  (64UL << 20)
#define MB_OFF    0x1000          /* mailbox 0x301000 within window @0x300000 */

void _start(void)
{
    static const char path[] = "/dev/uio0";
    volatile u32 *mb;
    long fd, i;
    struct { long sec; long nsec; } ts;

    puts_("== mbox gate test via /dev/uio0 ==\n");

    fd = sys6(SYS_openat, -100 /*AT_FDCWD*/, (long)path, 2 /*O_RDWR*/, 0, 0, 0);
    if (fd < 0) { puts_("open /dev/uio0 FAILED\n"); sys_exit(1); }

    mb = (volatile u32 *)sys6(SYS_mmap, 0, WIN_SIZE, PROT_RW, MAP_SHARED, fd, 0);
    if ((long)mb < 0 && (long)mb > -4096) { puts_("mmap FAILED\n"); sys_exit(1); }
    mb = (volatile u32 *)((char *)mb + MB_OFF);

    puts_("-- before magic --\n");
    for (i = 0; i < 8; i++) { puthex(mb[i]); }

    puts_("-- write IN=0x302000, OUT=0x470000, CTRL=0 --\n");
    mb[3] = 0;                 /* +0x0C CTRL */
    mb[0] = 0x00302000u;       /* +0x00 IN  (valid range -> boot) */
    mb[1] = 0x00470000u;       /* +0x04 OUT (valid range -> boot) */
    asm volatile("dsb sy" ::: "memory");

    for (i = 0; i < 4; i++) {
        ts.sec = 0; ts.nsec = 50000000; /* 50 ms x4 = 200 ms */
        sys6(SYS_nanosleep, (long)&ts, 0, 0, 0, 0, 0);
    }

    puts_("-- after valid IN/OUT (expect STATUS=0, VERSION=0x20261018, CTRL=0) --\n");
    puts_("STATUS:\n");  puthex(mb[4]);
    puts_("LAYER:\n");   puthex(mb[5]);
    puts_("VERSION:\n"); puthex(mb[6]);   /* +0x18, not mb[5] */
    puts_("CTRL:\n");    puthex(mb[3]);
    puts_("SLOT:\n");    puthex(mb[2]);

    sys_exit(0);
}
