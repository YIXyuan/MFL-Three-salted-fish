# -----------------------------------------------------------------------------
# sim_wram_bank.do -- M7 kosmo2_wram_bank 单元 + M6 联仿（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_wram_bank
#         --with ip/kosmo2_pe_layer --with ip/kosmo2_line_buffer
#         --with ip/kosmo2_mac_array --with ip/kosmo2_requant
#         --do sim_wram_bank.do
# 注意: -voptargs=+acc 保留信号可见性
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_wram_bank_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_const_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_v1_0.v
vlog -quiet ../../rtl/kosmo2_pe_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_line_buffer_v1_0.v
vlog -quiet ../../rtl/kosmo2_mac_array_v1_0.v
vlog -quiet ../../rtl/kosmo2_requant_v1_0.v
vlog -quiet ../tb_wram_bank_v1_0.v
vsim -voptargs=+acc tb_wram_bank_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/w_bank}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/w_col_idx}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/w_col}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/joint_mode}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/u_pe/st}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/u_pe/x_cur}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/u_pe/o_cur}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/u_pe/ph}
catch {add wave -radix hexadecimal sim:/tb_wram_bank_v1_0/u_pe/wr_valid}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
