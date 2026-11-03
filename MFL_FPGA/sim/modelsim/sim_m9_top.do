# -----------------------------------------------------------------------------
# sim_m9_top.do -- M9 kosmo2_m9_top 集成仿真（ModelSim）
# 批量: python tools/run_sim.py --ip ip/kosmo2_m9_top
#   --with ip/kosmo2_ctrl_fsm --with ip/kosmo2_pe_layer
#   --with ip/kosmo2_line_buffer --with ip/kosmo2_mac_array
#   --with ip/kosmo2_requant --with ip/kosmo2_wram_bank
#   --with ip/kosmo2_axi_dma_rd --with ip/kosmo2_axi_dma_wr
#   --with ../Kosmo2_IP/Kosmo2_IP/ip/kosmo2_pu_ddr_bridge --do sim_m9_top.do
# 注意: -voptargs=+acc 保留信号可见性
# -----------------------------------------------------------------------------
vlib work
vlog -quiet ../../rtl/kosmo2_mailbox_axi_master_v1_0.v
vlog -quiet ../../rtl/kosmo2_axi_mux_2to1_v1_0.v
vlog -quiet ../../rtl/kosmo2_mailbox_adapter_v1_0.v
vlog -quiet ../../rtl/kosmo2_m9_top_v1_0.v
vlog -quiet ../../rtl/kosmo2_ctrl_fsm_v1_0.v
vlog -quiet ../../rtl/kosmo2_boundary_v1_0.v
vlog -quiet ../../rtl/kosmo2_layer_cfg_rom_v1_0.v
vlog -quiet ../../rtl/kosmo2_pe_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_line_buffer_v1_0.v
vlog -quiet ../../rtl/kosmo2_mac_array_v1_0.v
vlog -quiet ../../rtl/kosmo2_requant_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_layer_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_const_v1_0.v
vlog -quiet ../../rtl/kosmo2_wram_bank_v1_0.v
vlog -quiet ../../rtl/kosmo2_axi_dma_rd_v1_0.v
vlog -quiet ../../rtl/kosmo2_axi_dma_wr_v1_0.v
vlog -quiet ../../rtl/kosmo2_rst_sync_v1_0.v
vlog -quiet ../../rtl/kosmo2_ddr_access_top_v1_0.v
vlog -quiet ../../rtl/kosmo2_ddr_bist_v1_0.v
vlog -quiet ../../rtl/kosmo2_axi_arb2_v1_0.v
vlog -quiet ../../rtl/kosmo2_pu_ddr_bridge_v1_0.v
vlog -quiet ../../rtl/kosmo2_async_fifo_v1_0.v
vlog -quiet ../kosmo2_pu_sps_model_v1_0.v
vlog -quiet ../tb_m9_top_v1_0.v
vlog -quiet ../tb_m9_drain_fail_v1_0.v
vsim -voptargs=+acc tb_m9_top_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_adapter/dbg_state}
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_adapter/status_last}
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_m8/k}
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_m8/dbg_state}
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_mux/sel}
catch {add wave -radix hexadecimal sim:/tb_m9_top_v1_0/u_m9/u_m8/m6_start}
run -all
# ---- 第二个 TB: 软复位排空超时（RESET_FAIL）----
vsim -voptargs=+acc tb_m9_drain_fail_v1_0
onfinish stop
catch {add wave -radix hexadecimal sim:/tb_m9_drain_fail_v1_0/u_m9/u_adapter/dbg_state}
catch {add wave -radix hexadecimal sim:/tb_m9_drain_fail_v1_0/u_m9/u_adapter/status_last}
run -all
# 本脚本不写 quit: 批量由 run_sim.py 追加; GUI 留给用户看完波形手动退出
