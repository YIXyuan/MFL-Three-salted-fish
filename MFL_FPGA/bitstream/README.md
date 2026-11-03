# bitstream —— 生产位流与启动镜像

| 文件 | md5 | 说明 |
|---|---|---|
| `AXI_wrapper.sbit` | `1a1847edee0196d1ba0095d1a5ed89c9` | 生产位流，2026-10-29 22:01:06 综合，晚于全部 RTL |
| `BOOT_PG.bin` | `ccb6fd8fb27aafdc9499ce2338afdb3a` | 启动镜像 18,286,592 B，PA 分区 @0x1B800（check_pa 校验过） |

## P&R 签核（report_timing / device_map）

- `pll_clk_50m` 50 MHz（Requested）/ **Estimated 60.3464 MHz**
- Setup **WNS +3.429 ns** / TNS 0 / 0 failing；Hold WHS +0.056 / 0 failing
- DRM 138.5/144（97%）、LUT 25,504、FF 22,390、APM 68、IO 6/125
- SCBV High Voltage，gen_bit_stream 无警告
- 板级参数：C_EXT_WORDS_EN=1、C_POLL_CYC=50000（1ms@50MHz）、C_DRAIN_CYC=25M、C_DONE_HOLD_CYC=25M

## 实机记录（此位流）

- 满尺寸全链 46,080 B ALL MATCH ×多次，busy 5760/5761/5762 ms
- 双帧 in-flight 2：A/B 各全对、hold=500 ms、无 0x6；软复位 2 ms 自清
- 批量端到端 114/114 帧（ARM 前端→FPGA→head→Web），5.93 s/帧，99/100 vs PC 参考

## 重新打包 BOOT_PG.bin

```bat
booter.exe -image board_tools\m9_boot_prod.icf     （输出 out_prod/，配方 v7：FSBL→PA→U-Boot→kernel→dtb→BL31）
python tools/check_pa.py <new.sbit> out_prod\BOOT_PG.bin   （期望 PA bitstream found at 0x1B800）
```
