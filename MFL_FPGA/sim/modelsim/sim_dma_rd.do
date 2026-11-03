# -----------------------------------------------------------------------------
# sim_dma_rd.do -- M2 kosmo2_axi_dma_rd 单元仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_axi_dma_rd --do sim_dma_rd.do
# GUI : python tools/run_sim.py --ip ip/kosmo2_axi_dma_rd --do sim_dma_rd.do --gui
# 注意: -voptargs=+acc 保留信号可见性, 否则 vopt 优化后 add wave 找不到对象
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_axi_dma_rd_v1_0.v
vlog -quiet ../tb_axi_dma_rd_v1_0.v
vsim -voptargs=+acc tb_axi_dma_rd_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_axi_dma_rd_v1_0/*}
catch {add wave -radix hexadecimal sim:/tb_axi_dma_rd_v1_0/u_dut/*}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
