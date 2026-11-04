#ifndef MFL_FPGA_REGS_H
#define MFL_FPGA_REGS_H

#define MFL_SHARED_PHYS_BASE   0x300000UL
#define MFL_SHARED_SIZE        (64UL * 1024 * 1024)
#define MFL_UIO_DEV            "/dev/uio0"

#define MFL_IN_BUF_OFF(slot)   ((slot) ? 0x01200000UL : 0x00002000UL)
#define MFL_OUT_BUF_OFF(slot)  (0x00170000UL)
#define MFL_IN_BUF_SIZE        (2UL * 1024 * 1024)
#define MFL_OUT_BUF_SIZE       (46UL * 1024)
#define MFL_OUT_IS_RUNTIME     1

#define MFL_SCRATCH_A_PHYS     0x500000UL
#define MFL_SCRATCH_B_PHYS     0xD00000UL

#define MFL_REG_BASE_DEFAULT   0x00301000UL

#define MFL_REG_IN_ADDR_OFF    0x0U
#define MFL_REG_OUT_ADDR_OFF   0x4U
#define MFL_REG_SLOT_OFF       0x8U
#define MFL_REG_CTRL_OFF       0xCU
#define MFL_REG_STATUS_OFF     0x10U
#define MFL_REG_LAYER_OFF      0x14U

#define MFL_REG_CTRL_START     0x1U
#define MFL_REG_STATUS_BUSY    0x1U
#define MFL_REG_STATUS_DONE    0x2U
#define MFL_REG_STATUS_ERR_BIT 0x4U
#define MFL_REG_STATUS_ERR     0x6U

#define MFL_LAYER_FULL         0x000000FFu
#define MFL_LAYER_SKIP_RELU    0x00000100u
#define MFL_LAYER_SKIP_POOL    0x00000200u

#define MFL_LAYER_ARM_POOL     (MFL_LAYER_SKIP_POOL | 0xFFu)

#define MFL_FPGA_IN_ELEMS      (3 * 480 * 1024)
#define MFL_FPGA_OUT_ELEMS     (96 * 15 * 32)
#define MFL_DEBUG_OUT_ELEMS    (96 * 30 * 64)
#define MFL_CONV09_OUT_ELEMS   MFL_DEBUG_OUT_ELEMS

#define MFL_FPGA_POLL_US       1000

#define MFL_FPGA_TIMEOUT_MS    180000

#define MFL_FPGA_ACK_GRACE_MS  2000

#endif
