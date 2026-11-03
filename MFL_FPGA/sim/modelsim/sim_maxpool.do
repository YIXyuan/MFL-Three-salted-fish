# -----------------------------------------------------------------------------
# sim_maxpool.do -- M5b kosmo2_maxpool 单元仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_maxpool --do sim_maxpool.do
# GUI : python tools/run_sim.py --ip ip/kosmo2_maxpool --do sim_maxpool.do --gui
# 注意: -voptargs=+acc 保留信号可见性
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_maxpool_v1_0.v
vlog -quiet ../tb_maxpool_v1_0.v
vsim -voptargs=+acc tb_maxpool_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_maxpool_v1_0/*}
catch {add wave -radix hexadecimal sim:/tb_maxpool_v1_0/u_dut/state}
catch {add wave -radix hexadecimal sim:/tb_maxpool_v1_0/u_dut/mx_r}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
