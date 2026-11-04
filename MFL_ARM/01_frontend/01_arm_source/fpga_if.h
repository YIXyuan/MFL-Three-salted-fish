#ifndef MFL_FPGA_IF_H
#define MFL_FPGA_IF_H

#include <stdint.h>
#include "fpga_regs.h"

enum {
    MFL_FPGA_OK          = 0,
    MFL_FPGA_ERR_OPEN    = -1,
    MFL_FPGA_ERR_MAP     = -2,
    MFL_FPGA_ERR_STUB_IO = -3,
    MFL_FPGA_ERR_TIMEOUT = -4,
    MFL_FPGA_ERR_ARGS    = -5,
    MFL_FPGA_ERR_HW      = -6

};

int  mfl_fpga_init(const char *stub_dir, unsigned long reg_base);
void mfl_fpga_deinit(void);
int  mfl_fpga_is_stub(void);

int8_t *mfl_fpga_in_buf(int slot);

void mfl_fpga_set_layer(unsigned v);
int  mfl_fpga_submit(int slot, const char *frame_tag);

const int8_t *mfl_fpga_wait_complete(int slot);

int  mfl_fpga_last_error(void);

#endif
