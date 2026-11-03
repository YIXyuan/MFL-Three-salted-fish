# -----------------------------------------------------------------------------
# sim_ctrl_fsm.do -- M8 kosmo2_ctrl_fsm 单元+全链仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_ctrl_fsm
#         --with ip/kosmo2_pe_layer --with ip/kosmo2_line_buffer
#         --with ip/kosmo2_mac_array --with ip/kosmo2_requant
#         --with ip/kosmo2_wram_bank --do sim_ctrl_fsm.do
# 注意: -voptargs=+acc 保留信号可见性
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_layer_cfg_rom_v1_0.v
vlog -quiet ../../rtl/kosmo2_boundary_v1_0.v
vlog -quiet ../../rtl/kosmo2_ctrl_fsm_v1_0.v
vlog -quiet ../../rtl/kosmo2_pe_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_line_buffer_v1_0.v
vlog -quiet ../../rtl/kosmo2_mac_array_v1_0.v
vlog -quiet ../../rtl/kosmo2_requant_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_const_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_v1_0.v
vlog -quiet ../tb_ctrl_fsm_v1_0.v
vsim -voptargs=+acc tb_ctrl_fsm_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/dbg_state}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/k}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/busy_r}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/done_o}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/err_o}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/owner_bnd}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/u_pe/st}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/u_pe/x_cur}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/u_pe/o_cur}
catch {add wave -radix hexadecimal sim:/tb_ctrl_fsm_v1_0/u_dut/u_bnd/st}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
