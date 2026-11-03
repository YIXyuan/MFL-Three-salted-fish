/* bist_check.c -- verify the 64 KiB BIST pattern in DDR 0xC80000..0xC8FFFF.
 * beat i: word0=seed^~i, word1=seed-i, word2=seed+i, word3=seed^i (seed=0xbeef1234)
 * reports: total beats, first mismatch beat, last good beat, per-quarter summary */
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
#define SYS_exit_group 94

static void sys_exit(int c){ sys6(SYS_exit_group,c,0,0,0,0,0); }
static void puts_(const char*s){long n=0;while(s[n])n++;sys6(SYS_write,1,(long)s,n,0,0,0);}
static void puthex(u64 v){char b[20];int i;b[0]='0';b[1]='x';
 for(i=0;i<8;i++){int d=(int)((v>>((7-i)*4))&0xF);b[2+i]=d<10?'0'+d:'a'+d-10;}
 b[10]='\n';sys6(SYS_write,1,(long)b,11,0,0,0);}
void *memset(void*d,int c,unsigned long n){unsigned char*p=d;while(n--)*p++=(unsigned char)c;return d;}
void *memcpy(void*d,const void*s,unsigned long n){unsigned char*p=d;const unsigned char*q=s;while(n--)*p++=*q++;return d;}

void _start(void)
{
    static const char path[] = "/dev/uio0";
    volatile u32 *region;
    long fd, i;
    int total = 4096, good = 0, first_bad = -1, last_good = -1;
    u32 seed = 0xBEEF1234u;

    fd = sys6(SYS_openat, -100, (long)path, 2, 0, 0, 0);
    if (fd < 0) { puts_("open FAIL\n"); sys_exit(1); }
    region = (volatile u32 *)sys6(SYS_mmap, 0, (64UL<<20), 3, 1, fd, 0);
    if ((long)region < 0 && (long)region > -4096) { puts_("mmap FAIL\n"); sys_exit(1); }
    region = (volatile u32 *)((char *)region + 0x980000); /* phys 0xC80000 */

    for (i = 0; i < total; i++) {
        u32 w0 = region[i*4+0], w1 = region[i*4+1];
        u32 w2 = region[i*4+2], w3 = region[i*4+3];
        u32 e0 = seed ^ ~((u32)i), e1 = seed - (u32)i;
        u32 e2 = seed + (u32)i,  e3 = seed ^  (u32)i;
        if (w0 == e0 && w1 == e1 && w2 == e2 && w3 == e3) {
            good++;
            last_good = (int)i;
        } else if (first_bad < 0) {
            first_bad = (int)i;
            puts_("first bad beat=");  puthex((u64)i);
            puts_("  got w0="); puthex(w0);
            puts_("      exp w0="); puthex(e0);
        }
    }
    puts_("good beats ="); puthex((u64)good);
    puts_("last good  ="); puthex((u64)(last_good < 0 ? -1 : last_good));
    puts_("first bad  ="); puthex((u64)(first_bad < 0 ? -1 : first_bad));
    sys_exit(0);
}
