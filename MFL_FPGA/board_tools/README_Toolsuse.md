# 09_board_tools 使用说明

## 板端可执行（静态 aarch64，scp 到板 /tmp 后 chmod +x）

| 工具 | 用法 | 说明 |
|---|---|---|
| `m9_full` | `probe` / `boot` / `full <in.bin> [exp.bin] [out.bin]` / `dual <inA> <expA> <inB> [expB]` / `dump <off_hex> <len> <out.bin>` / `softreset` / `export N <in.bin> <scratch>` | 主工具，免 libc（raw syscall + /dev/uio0 mmap）。`full` = 写 IN→LAYER=0xFF→START→轮询→46,080 B 对拍（实测 5761 ms）；`dual` = in-flight 2 / 1 深 pending（A/B 各自对拍、hold 500 ms）；`export N` = 逐层 pre-ReLU 导出（仅用于结构对齐：该路径会把负值压成 `0x80`，不能当数值基准） |
| `mbox_gate_test` | 直接跑 | dump 邮箱 8 字 → 写有效 IN/OUT → 200 ms 后复查 VERSION/STATUS（开锁判据） |
| `bist_check` | 直接跑 | CPU 侧逐拍核对 0xC80000 的 64 KiB BIST 图案（seed=0xbeef1234） |
| `m9_bringup.c` | 交叉编译备用（Linaro `-static`） | 与 m9_full 同功能的前身，板上未部署 |

## 主机脚本

| 脚本 | 用法 | 说明 |
|---|---|---|
| `check_pa.py` | `python check_pa.py <new.sbit> <BOOT_PG.bin>` | 校验打包镜像里 PA 位流（字内字节交换形式）落在 0x1B800 |
| `gen_m9_full_vec.py` | `[--sample <名|目录>] [--out-dir <dir>]` | 满尺寸十层金标准生成（quant_export 口径，自动核对 layer_cfg.mem） |
| `mfl_resize_1024x480.py` | `<原图...> -o <dir> [--start 1]` | 原图→1024×480 JPEG（板端不缩放的前置），保留源编号命名 P####_001，输出 `_map.csv` |
| `m9_boot_prod.icf` / `m9_boot_dbg4/5.icf` | `booter.exe -image <icf>` | BOOT_PG.bin 打包单（v7 配方：FSBL→PA 位流→U-Boot→kernel→dtb→BL31） |

