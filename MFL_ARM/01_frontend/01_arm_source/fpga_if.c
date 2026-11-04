#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "fpga_if.h"

static int g_last_err = MFL_FPGA_OK;

static int      g_real_ready = 0;
static int      g_uio_fd = -1, g_mem_fd = -1;
static long     g_timeout_ms = MFL_FPGA_TIMEOUT_MS;
static uint8_t *g_shared = NULL;
static volatile uint32_t *g_regs = NULL;
static unsigned long g_reg_base = 0;

static char     g_stub_dir[512] = "";
static int8_t  *g_stub_out[2];
static int8_t  *g_stub_in[2];
static char     g_stub_tag[2][64];

static void reg_w(unsigned long off, uint32_t v) { g_regs[off / 4] = v; }
static uint32_t reg_r(unsigned long off)         { return g_regs[off / 4]; }

static size_t npy_data_offset(const uint8_t *buf, size_t size)
{
    if (size < 12 || memcmp(buf, "\x93NUMPY", 6) != 0) return 0;
    if (buf[6] != 1) {
        fprintf(stderr, "[fpga_if] npy 版本非 v1 (%u), 不支持\n", buf[6]);
        return 0;
    }
    size_t hlen = (size_t)buf[8] | ((size_t)buf[9] << 8);
    size_t off = 10 + hlen;
    if (off >= size) return 0;
    return off;
}

static unsigned g_layer_val = 0x000000FFu;

void mfl_fpga_set_layer(unsigned v) { g_layer_val = v; }

int mfl_fpga_init(const char *stub_dir, unsigned long reg_base)
{
    g_last_err = MFL_FPGA_OK;

    if (stub_dir && stub_dir[0]) {
        snprintf(g_stub_dir, sizeof(g_stub_dir), "%s", stub_dir);
        for (int s = 0; s < 2; s++) {
            g_stub_in[s]  = malloc((size_t)MFL_FPGA_IN_ELEMS);
            g_stub_out[s] = malloc((size_t)MFL_CONV09_OUT_ELEMS);
            g_stub_tag[s][0] = '\0';
            if (!g_stub_in[s] || !g_stub_out[s]) {
                fprintf(stderr, "[fpga_if] stub 缓冲分配失败\n");
                g_last_err = MFL_FPGA_ERR_MAP;
                return g_last_err;
            }
        }
        fprintf(stderr, "[fpga_if] STUB 模式, 向量目录: %s "
                "(conv09 结果来自 PC 向量, FPGA 未参与)\n", g_stub_dir);
        return MFL_FPGA_OK;
    }

    g_reg_base = reg_base ? reg_base : MFL_REG_BASE_DEFAULT;

    g_timeout_ms = MFL_FPGA_TIMEOUT_MS;
    {
        const char *e = getenv("MFL_FPGA_TIMEOUT_MS");
        if (e && e[0]) {
            long v = atol(e);
            if (v >= 1000) g_timeout_ms = v;
            else fprintf(stderr, "[fpga_if] MFL_FPGA_TIMEOUT_MS=%s <1000, 忽略\n", e);
        }
    }

    g_uio_fd = open(MFL_UIO_DEV, O_RDWR | O_SYNC);
    if (g_uio_fd < 0) {
        fprintf(stderr, "[fpga_if] 打不开 %s: %s (在板上? root 权限?)\n",
                MFL_UIO_DEV, strerror(errno));
        g_last_err = MFL_FPGA_ERR_OPEN;
        return g_last_err;
    }
    g_shared = mmap(NULL, MFL_SHARED_SIZE, PROT_READ | PROT_WRITE,
                    MAP_SHARED, g_uio_fd, 0);
    if (g_shared == MAP_FAILED) {
        fprintf(stderr, "[fpga_if] 共享窗 mmap 失败: %s\n", strerror(errno));
        close(g_uio_fd); g_uio_fd = -1; g_shared = NULL;
        g_last_err = MFL_FPGA_ERR_MAP;
        return g_last_err;
    }

    if (g_reg_base < MFL_SHARED_PHYS_BASE ||
        g_reg_base + 0x1000UL > MFL_SHARED_PHYS_BASE + MFL_SHARED_SIZE) {
        fprintf(stderr, "[fpga_if] 邮箱基址 0x%lx 在共享窗[0x%lx,+0x%lx)外——非法配置\n",
                g_reg_base, (unsigned long)MFL_SHARED_PHYS_BASE,
                (unsigned long)MFL_SHARED_SIZE);
        munmap(g_shared, MFL_SHARED_SIZE); g_shared = NULL;
        close(g_uio_fd); g_uio_fd = -1;
        g_last_err = MFL_FPGA_ERR_MAP;
        return g_last_err;
    }
    if (g_reg_base & 0xFFFUL) {
        fprintf(stderr, "[fpga_if] 邮箱基址 0x%lx 未 4K 对齐\n", g_reg_base);
        munmap(g_shared, MFL_SHARED_SIZE); g_shared = NULL;
        close(g_uio_fd); g_uio_fd = -1;
        g_last_err = MFL_FPGA_ERR_MAP;
        return g_last_err;
    }
    g_regs = (volatile uint32_t *)(void *)(g_shared + (g_reg_base - MFL_SHARED_PHYS_BASE));
    g_mem_fd = -1;

    g_real_ready = 1;
    fprintf(stderr, "[fpga_if] 实模式: shared=0x%lx(64MiB) 邮箱=0x%lx "
            "(uio 单映射, RCPT-01 已逐项核对)\n",
            (unsigned long)MFL_SHARED_PHYS_BASE, g_reg_base);
    return MFL_FPGA_OK;
}

void mfl_fpga_deinit(void)
{
    if (g_stub_dir[0]) {
        for (int s = 0; s < 2; s++) {
            free(g_stub_in[s]);  g_stub_in[s] = NULL;
            free(g_stub_out[s]); g_stub_out[s] = NULL;
        }
        g_stub_dir[0] = '\0';
        return;
    }
    if (g_regs) g_regs = NULL;
    if (g_shared) { munmap(g_shared, MFL_SHARED_SIZE); g_shared = NULL; }
    if (g_mem_fd >= 0) { close(g_mem_fd); g_mem_fd = -1; }
    if (g_uio_fd >= 0) { close(g_uio_fd); g_uio_fd = -1; }
    g_real_ready = 0;
}

int mfl_fpga_is_stub(void) { return g_stub_dir[0] ? 1 : 0; }

int8_t *mfl_fpga_in_buf(int slot)
{
    if (slot != 0 && slot != 1) return NULL;
    if (g_stub_dir[0]) return g_stub_in[slot];
    if (!g_real_ready) return NULL;
    return (int8_t *)(g_shared + MFL_IN_BUF_OFF(slot));
}

int mfl_fpga_submit(int slot, const char *frame_tag)
{
    if (slot != 0 && slot != 1) { g_last_err = MFL_FPGA_ERR_ARGS; return g_last_err; }

    if (g_stub_dir[0]) {
        snprintf(g_stub_tag[slot], sizeof(g_stub_tag[slot]), "%s",
                 frame_tag ? frame_tag : "");
        return MFL_FPGA_OK;
    }

    if (!g_real_ready) { g_last_err = MFL_FPGA_ERR_OPEN; return g_last_err; }
    reg_w(MFL_REG_IN_ADDR_OFF,  (uint32_t)(MFL_SHARED_PHYS_BASE + MFL_IN_BUF_OFF(slot)));
    reg_w(MFL_REG_OUT_ADDR_OFF, (uint32_t)(MFL_SHARED_PHYS_BASE + MFL_OUT_BUF_OFF(slot)));
    reg_w(MFL_REG_SLOT_OFF,     (uint32_t)slot);
    reg_w(MFL_REG_LAYER_OFF,    g_layer_val);

    int ack = 0;
    for (int try_i = 0; try_i < 20 && !ack; try_i++) {
        if (try_i) { reg_w(MFL_REG_CTRL_OFF, 0u); usleep(2000); }
        reg_w(MFL_REG_CTRL_OFF,     MFL_REG_CTRL_START);
        for (int k = 0; k < 20; k++) {
            if (reg_r(MFL_REG_STATUS_OFF) & MFL_REG_STATUS_BUSY) { ack = 1; break; }
            usleep(1000);
        }
    }
    if (!ack) {
        fprintf(stderr, "[fpga_if] slot%d 启动未被受理(20 次重试), STATUS=0x%x "
                        "(邮箱链断 / 位流未含 regbox)\n", slot, reg_r(MFL_REG_STATUS_OFF));
        g_last_err = MFL_FPGA_ERR_TIMEOUT;
        return g_last_err;
    }

    return MFL_FPGA_OK;
}

const int8_t *mfl_fpga_wait_complete(int slot)
{
    if (slot != 0 && slot != 1) { g_last_err = MFL_FPGA_ERR_ARGS; return NULL; }

    if (g_stub_dir[0]) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/", g_stub_dir);
        size_t dl = strlen(path);
        const char *tag = g_stub_tag[slot];
        const char *dot = strrchr(tag, '.');
        size_t stem = dot ? (size_t)(dot - tag) : strlen(tag);
        if (dl + stem + 32 >= sizeof(path) || stem == 0) {
            g_last_err = MFL_FPGA_ERR_ARGS;
            return NULL;
        }
        memcpy(path + dl, tag, stem);
        path[dl + stem] = '\0';
        strcat(path, ".conv09_out_int8.npy");

        FILE *f = fopen(path, "rb");
        if (!f) {
            fprintf(stderr, "[fpga_if] stub 向量缺失: %s "
                    "(PC 端按 new_name 生成, 见 export 脚本)\n", path);
            g_last_err = MFL_FPGA_ERR_STUB_IO;
            return NULL;
        }
        fseek(f, 0, SEEK_END);
        long fsz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (fsz < (long)MFL_CONV09_OUT_ELEMS) {
            fprintf(stderr, "[fpga_if] stub 向量过小(%ld): %s\n", fsz, path);
            fclose(f);
            g_last_err = MFL_FPGA_ERR_STUB_IO;
            return NULL;
        }
        uint8_t *raw = malloc((size_t)fsz);
        size_t n = fread(raw, 1, (size_t)fsz, f);
        fclose(f);
        if (n != (size_t)fsz) n = 0;

        size_t off = npy_data_offset(raw, n);
        if (off == 0) {
            off = 0;
            if (n != (size_t)MFL_CONV09_OUT_ELEMS) {
                fprintf(stderr, "[fpga_if] stub 向量尺寸 %zu != %d: %s\n",
                        n, MFL_CONV09_OUT_ELEMS, path);
                free(raw);
                g_last_err = MFL_FPGA_ERR_STUB_IO;
                return NULL;
            }
        } else if (n - off < (size_t)MFL_CONV09_OUT_ELEMS) {
            fprintf(stderr, "[fpga_if] stub npy 数据不足(%zu): %s\n",
                    n - off, path);
            free(raw);
            g_last_err = MFL_FPGA_ERR_STUB_IO;
            return NULL;
        }
        memcpy(g_stub_out[slot], raw + off, (size_t)MFL_CONV09_OUT_ELEMS);
        free(raw);
        return g_stub_out[slot];
    }

    if (!g_real_ready) { g_last_err = MFL_FPGA_ERR_OPEN; return NULL; }

    struct timespec ts0;
    clock_gettime(CLOCK_MONOTONIC, &ts0);
    int seen_busy = 0;

    for (;;) {
        uint32_t st = reg_r(MFL_REG_STATUS_OFF);
        if (seen_busy) {

            if (st & MFL_REG_STATUS_ERR_BIT) {
                fprintf(stderr, "[fpga_if] slot%d 帧错误 STATUS=0x%x (OUT 无效)\n",
                        slot, st);
                g_last_err = MFL_FPGA_ERR_HW;
                return NULL;
            }
            if (st & MFL_REG_STATUS_DONE) {
                return (const int8_t *)(g_shared + MFL_OUT_BUF_OFF(slot));
            }
        } else if (st & MFL_REG_STATUS_BUSY) {
            seen_busy = 1;
        }

        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long ms = (now.tv_sec - ts0.tv_sec) * 1000
                + (now.tv_nsec - ts0.tv_nsec) / 1000000;
        if (!seen_busy && ms > MFL_FPGA_ACK_GRACE_MS) {
            fprintf(stderr, "[fpga_if] slot%d 未受理: %ldms 无 BUSY, STATUS=0x%x "
                            "(CTRL 未回 0 / 邮箱链断 / 位流未含 regbox)\n",
                    slot, ms, st);
            g_last_err = MFL_FPGA_ERR_TIMEOUT;
            return NULL;
        }
        if (ms > g_timeout_ms) {
            fprintf(stderr, "[fpga_if] slot%d 超时(%ldms, 上限 %ldms), STATUS=0x%x "
                            "(50MHz 整链实测≈111s; env MFL_FPGA_TIMEOUT_MS 可调)\n",
                    slot, ms, g_timeout_ms, st);
            g_last_err = MFL_FPGA_ERR_TIMEOUT;
            return NULL;
        }

        usleep(ms < 2000 ? MFL_FPGA_POLL_US : 10 * MFL_FPGA_POLL_US);
    }
}

int mfl_fpga_last_error(void) { return g_last_err; }
