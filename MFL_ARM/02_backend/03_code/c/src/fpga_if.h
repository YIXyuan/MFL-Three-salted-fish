#ifndef MFL_FPGA_IF_H
#define MFL_FPGA_IF_H

#include <stdint.h>
#include <stddef.h>

#define FPGA_REG_IN_ADDR    0x00u
#define FPGA_REG_OUT_ADDR   0x04u
#define FPGA_REG_SLOT       0x08u
#define FPGA_REG_CTRL       0x0Cu
#define FPGA_REG_STATUS     0x10u
#define FPGA_REG_LAYER      0x14u
#define FPGA_REG_VERSION    0x18u
#define FPGA_REG_RESET      0x1Cu

#define FPGA_CTRL_START     0x1u

#define FPGA_STATUS_IDLE     0x0u
#define FPGA_STATUS_BUSY     0x1u
#define FPGA_STATUS_DONE     0x2u
#define FPGA_STATUS_ERR      0x4u
#define FPGA_STATUS_DONE_ERR 0x6u

#define FPGA_VERSION_RESET_AVAILABLE(v) ((v) != 0u)

int  mfl_fpga_version_valid(uint32_t v);

#define FPGA_LAYER_FULL       0xFFu
#define FPGA_LAYER_FULL_NORELU 0x1FFu
#define FPGA_LAYER_NOPOOL     0x2FFu
#define FPGA_LAYER_EXPORT(n)  (0x300u | ((n) & 0xFFu))

#define FPGA_MAILBOX_OFF     0x001000u
#define FPGA_IN0_OFF         0x002000u
#define FPGA_IN1_OFF         0x1200000u
#define FPGA_OUT_OFF         0x170000u
#define FPGA_WINDOW_PHYS     0x00300000u
#define FPGA_WINDOW_SIZE     (64u * 1024u * 1024u)

#define FPGA_IN_BYTES        1474560u
#define FPGA_OUT_BYTES       46080u
#define FPGA_OUT_BYTES_30    184320u

#define FPGA_TIMEOUT_MS_DEFAULT 15000
#define FPGA_RESET_TIMEOUT_MS   1000

typedef struct {
    uint32_t window_phys;
    size_t   window_size;
    uint32_t mailbox_off;
    uint32_t in_off[2];
    uint32_t out_off;
    int      timeout_ms;
} mfl_fpga_cfg_t;

typedef struct {
    int       uio_fd;
    uint8_t  *shared;
    volatile uint32_t *regs;
    mfl_fpga_cfg_t cfg;
    uint32_t  version;
} mfl_fpga_t;

void mfl_fpga_cfg_default(mfl_fpga_cfg_t *cfg);

int  mfl_fpga_open(mfl_fpga_t *f, const char *uio_dev, const mfl_fpga_cfg_t *cfg);

void mfl_fpga_close(mfl_fpga_t *f);

int  mfl_fpga_submit(mfl_fpga_t *f, int slot, const int8_t *input,
                     size_t bytes, uint32_t layer);

int  mfl_fpga_wait_done(mfl_fpga_t *f, int timeout_ms);

const int8_t *mfl_fpga_out_buf(const mfl_fpga_t *f);

void mfl_fpga_clear(mfl_fpga_t *f);

uint32_t mfl_fpga_version(const mfl_fpga_t *f);

int  mfl_fpga_reset(mfl_fpga_t *f);

void mfl_fpga_dump_mailbox(const mfl_fpga_t *f, uint32_t out[8]);

#endif
