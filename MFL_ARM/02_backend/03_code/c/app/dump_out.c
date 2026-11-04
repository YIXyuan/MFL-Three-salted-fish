#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define OUT_OFF  0x170000u
#define OUT_BYTES 46080u

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "用法: %s <out.bin>\n", argv[0]); return 2; }
    int fd = open("/dev/uio0", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/uio0"); return 1; }
    void *p = mmap(NULL, 64u * 1024 * 1024, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 1; }
    size_t n = fwrite((const char *)p + OUT_OFF, 1, OUT_BYTES, f);
    fclose(f);
    munmap(p, 64u * 1024 * 1024);
    close(fd);
    printf("wrote %zu bytes\n", n);
    return n == OUT_BYTES ? 0 : 1;
}
