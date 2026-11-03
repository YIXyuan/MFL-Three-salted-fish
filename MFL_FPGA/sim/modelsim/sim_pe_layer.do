# -----------------------------------------------------------------------------
# sim_pe_layer.do -- M6 kosmo2_pe_layer 单元仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_pe_layer
#         --with ip/kosmo2_line_buffer --with ip/kosmo2_mac_array
#         --with ip/kosmo2_requant --do sim_pe_layer.do
# 注意: -voptargs=+acc 保留信号可见性
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_pe_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_line_buffer_v1_0.v
vlog -quiet ../../rtl/kosmo2_mac_array_v1_0.v
vlog -quiet ../../rtl/kosmo2_requant_v1_0.v
vlog -quiet ../tb_pe_layer_v1_0.v
vsim -voptargs=+acc tb_pe_layer_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/st}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/ph}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/x_cur}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/o_cur}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/rq_q_valid}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/wr_valid}
catch {add wave -radix hexadecimal sim:/tb_pe_layer_v1_0/u_dut/rd_valid}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
