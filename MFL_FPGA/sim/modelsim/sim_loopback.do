# -----------------------------------------------------------------------------
# sim_loopback.do -- M2 闭环: 读主 -> 流 -> 写主 -> DDR 回环自校验（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_axi_dma_wr --with ip/kosmo2_axi_dma_rd --do sim_loopback.do
#       （--with 把读主 RTL 并入临时编译目录, 供跨 IP 回环 TB 使用）
# GUI : python tools/run_sim.py --ip ip/kosmo2_axi_dma_wr --with ip/kosmo2_axi_dma_rd --do sim_loopback.do --gui
# 注意: -voptargs=+acc 保留信号可见性, 否则 vopt 优化后 add wave 找不到对象
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_axi_dma_rd_v1_0.v
vlog -quiet ../../rtl/kosmo2_axi_dma_wr_v1_0.v
vlog -quiet ../tb_dma_loopback.v
vsim -voptargs=+acc tb_dma_loopback
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_dma_loopback/*}
catch {add wave -radix hexadecimal sim:/tb_dma_loopback/u_rd/*}
catch {add wave -radix hexadecimal sim:/tb_dma_loopback/u_wr/*}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
