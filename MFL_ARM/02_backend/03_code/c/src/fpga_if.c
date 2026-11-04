#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "fpga_if.h"

int mfl_fpga_version_valid(uint32_t v)
{

    uint32_t rev = v >> 30;
    int y  = ((v >> 28) & 0xF) * 1000 + ((v >> 24) & 0xF) * 100
           + ((v >> 20) & 0xF) * 10   + ((v >> 16) & 0xF);
    int mo = ((v >> 12) & 0xF) * 10   + ((v >> 8) & 0xF);
    int d  = ((v >> 4) & 0xF) * 10    + (v & 0xF);
    return rev <= 3u && y >= 2020 && y <= 2099 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31;
}

#ifdef __linux__

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

static void sleep_ms(int ms)
{
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

void mfl_fpga_cfg_default(mfl_fpga_cfg_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->window_phys = FPGA_WINDOW_PHYS;
    cfg->window_size = FPGA_WINDOW_SIZE;
    cfg->mailbox_off = FPGA_MAILBOX_OFF;
    cfg->in_off[0]   = FPGA_IN0_OFF;
    cfg->in_off[1]   = FPGA_IN1_OFF;
    cfg->out_off     = FPGA_OUT_OFF;
    cfg->timeout_ms  = FPGA_TIMEOUT_MS_DEFAULT;
}

int mfl_fpga_open(mfl_fpga_t *f, const char *uio_dev, const mfl_fpga_cfg_t *cfg)
{
    memset(f, 0, sizeof(*f));
    f->uio_fd = -1;
    f->cfg = *cfg;

    int fd = open(uio_dev, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "fpga_if: open %s: %s\n", uio_dev, strerror(errno));
        return -1;
    }
    void *p = mmap(NULL, cfg->window_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "fpga_if: mmap %s len=0x%zx: %s\n",
                uio_dev, cfg->window_size, strerror(errno));
        close(fd);
        return -2;
    }
    f->uio_fd = fd;
    f->shared = (uint8_t *)p;
    f->regs = (volatile uint32_t *)(f->shared + cfg->mailbox_off);
    f->version = f->regs[FPGA_REG_VERSION / 4];
    return 0;
}

void mfl_fpga_close(mfl_fpga_t *f)
{
    if (f->shared) { munmap(f->shared, f->cfg.window_size); f->shared = NULL; }
    if (f->uio_fd >= 0) { close(f->uio_fd); f->uio_fd = -1; }
    f->regs = NULL;
}

uint32_t mfl_fpga_version(const mfl_fpga_t *f)
{
    return f->regs ? f->regs[FPGA_REG_VERSION / 4] : 0;
}

int mfl_fpga_submit(mfl_fpga_t *f, int slot, const int8_t *input,
                    size_t bytes, uint32_t layer)
{
    if (!f->shared || !f->regs) return -1;
    if (slot < 0 || slot > 1) return -2;
    if (!input || bytes == 0 || bytes > FPGA_IN_BYTES) return -2;

    uint32_t in_off = f->cfg.in_off[slot];
    memcpy(f->shared + in_off, input, bytes);
    __sync_synchronize();

    f->regs[FPGA_REG_IN_ADDR / 4]  = f->cfg.window_phys + in_off;
    f->regs[FPGA_REG_OUT_ADDR / 4] = f->cfg.window_phys + f->cfg.out_off;
    f->regs[FPGA_REG_LAYER / 4]    = layer;
    __sync_synchronize();
    f->regs[FPGA_REG_CTRL / 4]     = FPGA_CTRL_START;
    return 0;
}

int mfl_fpga_wait_done(mfl_fpga_t *f, int timeout_ms)
{
    if (!f->regs) return -3;
    if (timeout_ms <= 0) timeout_ms = FPGA_TIMEOUT_MS_DEFAULT;

    int t = 0, err_at = -1;

    for (;;) {
        uint32_t st = f->regs[FPGA_REG_STATUS / 4];
        if (st == FPGA_STATUS_BUSY) break;
        if (st & FPGA_STATUS_ERR) {
            if (err_at < 0) err_at = t;
            else if (t - err_at > 100) return -2;
        } else if (st != FPGA_STATUS_IDLE && st != FPGA_STATUS_DONE) {
            return -3;
        }
        if (t >= timeout_ms) return err_at >= 0 ? -2 : -1;
        sleep_ms(1); t++;
    }

    err_at = -1;
    for (;;) {
        uint32_t st = f->regs[FPGA_REG_STATUS / 4];
        if (st == FPGA_STATUS_DONE) return 0;
        if (st & FPGA_STATUS_ERR) {
            if (err_at < 0) err_at = t;
            else if (t - err_at > 100) return -2;
        } else if (st != FPGA_STATUS_BUSY && st != FPGA_STATUS_IDLE) {
            return -3;
        }
        if (t >= timeout_ms) return err_at >= 0 ? -2 : -1;
        sleep_ms(1); t++;
    }
}

const int8_t *mfl_fpga_out_buf(const mfl_fpga_t *f)
{
    return f->shared ? (const int8_t *)(f->shared + f->cfg.out_off) : NULL;
}

void mfl_fpga_clear(mfl_fpga_t *f)
{

    (void)f;
}

int mfl_fpga_reset(mfl_fpga_t *f)
{
    if (!f->regs) return -1;
    uint32_t ver = f->regs[FPGA_REG_VERSION / 4];
    if (!FPGA_VERSION_RESET_AVAILABLE(ver) || !mfl_fpga_version_valid(ver)) return -1;

    f->regs[FPGA_REG_RESET / 4] = 1u;

    int t = 0;
    while (t < FPGA_RESET_TIMEOUT_MS) {
        if (f->regs[FPGA_REG_RESET / 4] == 0u) break;
        sleep_ms(1); t++;
    }
    if (t >= FPGA_RESET_TIMEOUT_MS) return -2;

    uint32_t st = f->regs[FPGA_REG_STATUS / 4];
    if (st & FPGA_STATUS_ERR) return -3;
    if (st != FPGA_STATUS_IDLE) return -4;
    sleep_ms(1);
    return 0;
}

void mfl_fpga_dump_mailbox(const mfl_fpga_t *f, uint32_t out[8])
{
    for (int i = 0; i < 8; i++)
        out[i] = f->regs ? f->regs[i] : 0u;
}

#else

void mfl_fpga_cfg_default(mfl_fpga_cfg_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->window_phys = FPGA_WINDOW_PHYS;
    cfg->window_size = FPGA_WINDOW_SIZE;
    cfg->mailbox_off = FPGA_MAILBOX_OFF;
    cfg->in_off[0]   = FPGA_IN0_OFF;
    cfg->in_off[1]   = FPGA_IN1_OFF;
    cfg->out_off     = FPGA_OUT_OFF;
    cfg->timeout_ms  = FPGA_TIMEOUT_MS_DEFAULT;
}

int mfl_fpga_open(mfl_fpga_t *f, const char *uio_dev, const mfl_fpga_cfg_t *cfg)
{
    (void)uio_dev;
    memset(f, 0, sizeof(*f));
    f->uio_fd = -1;
    f->cfg = *cfg;
    fprintf(stderr, "fpga_if: 非 Linux 平台, 不支持在线 FPGA 模式\n");
    return -1;
}

void mfl_fpga_close(mfl_fpga_t *f) { memset(f, 0, sizeof(*f)); f->uio_fd = -1; }
uint32_t mfl_fpga_version(const mfl_fpga_t *f) { (void)f; return 0; }
int mfl_fpga_submit(mfl_fpga_t *f, int slot, const int8_t *in, size_t n, uint32_t layer)
{ (void)f; (void)slot; (void)in; (void)n; (void)layer; return -1; }
int mfl_fpga_wait_done(mfl_fpga_t *f, int t) { (void)f; (void)t; return -1; }
const int8_t *mfl_fpga_out_buf(const mfl_fpga_t *f) { (void)f; return NULL; }
void mfl_fpga_clear(mfl_fpga_t *f) { (void)f; }
int mfl_fpga_reset(mfl_fpga_t *f) { (void)f; return -1; }
void mfl_fpga_dump_mailbox(const mfl_fpga_t *f, uint32_t out[8])
{ (void)f; for (int i = 0; i < 8; i++) out[i] = 0; }

#endif
