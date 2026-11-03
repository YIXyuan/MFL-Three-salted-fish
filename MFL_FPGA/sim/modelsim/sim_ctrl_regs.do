# -----------------------------------------------------------------------------
# sim_ctrl_regs.do -- M1 kosmo2_ctrl_regs 单元仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_ctrl_regs --do sim_ctrl_regs.do
#       （run_sim.py 自动在批量的 do 之后追加 quit -f）
# GUI : python tools/run_sim.py --ip ip/kosmo2_ctrl_regs --do sim_ctrl_regs.do --gui
#       （run 结束后自动停下，可查看 wave 窗口再手动退出）
# 注意: -voptargs=+acc 保留信号可见性, 否则 vopt 优化后 add wave 找不到对象
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_ctrl_regs_v1_0.v
vlog -quiet ../tb_ctrl_regs_v1_0.v
vsim -voptargs=+acc tb_ctrl_regs_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_ctrl_regs_v1_0/*}
catch {add wave -radix hexadecimal sim:/tb_ctrl_regs_v1_0/u_dut/*}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
