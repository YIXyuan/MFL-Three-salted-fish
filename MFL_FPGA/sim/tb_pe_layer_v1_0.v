// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_pe_layer_v1_0.v
// Description : kosmo2_pe_layer_v1_0 自校验 testbench（M6）
//   * TB 三件外部环境: M7 权重库模型(w_col 2 拍延迟 + bias/mc 整行) /
//     M2 读服务器(按 rd_req 从 ddr 数组流 16B beat) / M2 写服务器(收段流落字节)
//   * T0: 单位权重(输出==relu(中心像素), 隔离扫描/对齐)
//   * T1: 合成小层 W=16 H=6 C=3 out=4（随机权重/Mc, 全层金模型）
//   * T2: 真实 conv00 参数 patch（v2 quant_export 权重/bias/Mc + 真实输入 patch）
//   向量由 tools\gen_m6_tb_vectors.py 生成（sim\vec\*.hex）
//   结束打印 TB PASS / TB FAIL
// 运行        : python tools/run_sim.py --ip ip/kosmo2_pe_layer
//               --with ip/kosmo2_line_buffer --with ip/kosmo2_mac_array
//               --with ip/kosmo2_requant --do sim_pe_layer.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pe_layer_v1_0;

    localparam integer CHM     = 96;
    localparam [31:0]  RD_BASE = 32'h0000_1000;
    localparam [31:0]  WR_BASE = 32'h0000_4000;

    reg         aclk, rst_n;
    reg  [6:0]  cfg_in_ch, cfg_out_ch;
    reg  [10:0] cfg_w, cfg_h;
    reg  [3:0]  cfg_bank_id;
    reg         cfg_relu_en;
    reg  [31:0] cfg_rd_base, cfg_wr_base;
    reg         cfg_load;
    reg         dbg_en;

    wire [3:0]    w_bank;
    wire [9:0]    w_col_idx;
    wire [2047:0] w_col;
    wire [8191:0] bias_line_r;
    wire [8191:0] mc_line_r;

    wire         rd_req;
    wire [31:0]  rd_req_addr;
    wire [10:0]  rd_req_len;
    wire         rd_ready;
    reg  [127:0] rd_data_r;
    reg          rd_valid_r;

    wire         wr_req;
    wire [31:0]  wr_req_addr;
    wire [10:0]  wr_req_len;
    wire [127:0] wr_data;
    wire         wr_valid;

    wire         busy_o, done_o;
    wire [2:0]   dbg_state;
    wire [10:0]  dbg_x, dbg_y;

    integer err_cnt;
    integer i, c, y, x, idx;

    // ---------------- 存储模型 ----------------
    reg [7:0]      ddr [0:131071];
    reg [2047:0]   wmem [0:1023];
    reg [31:0]     bias_arr [0:CHM-1];
    reg [31:0]     mc_arr   [0:CHM-1];
    reg [127:0]    inrow [0:1023];
    reg [7:0]      exp_arr [0:65535];
    reg [8191:0]   bias_line, mc_line;

    assign bias_line_r = bias_line;
    assign mc_line_r   = mc_line;

    // M7 权重列: 采样 w_col_idx 后 2 拍出数(与 M3 同定义)
    reg [2047:0] wq1, wq2;
    always @(posedge aclk) begin
        wq1 <= wmem[w_col_idx];
        wq2 <= wq1;
    end
    assign w_col = wq2;

    // ---------------- DUT ----------------
    kosmo2_pe_layer_v1_0 #(
        .C_CH_MAX(CHM), .C_X_BITS(11), .C_ROW_BYTES(16384)
    ) u_dut (
        .aclk(aclk), .rst_n(rst_n),
        .cfg_in_ch(cfg_in_ch), .cfg_out_ch(cfg_out_ch),
        .cfg_w(cfg_w), .cfg_h(cfg_h),
        .cfg_bank_id(cfg_bank_id), .cfg_relu_en(cfg_relu_en),
        .cfg_rd_base(cfg_rd_base), .cfg_wr_base(cfg_wr_base),
        .cfg_load(cfg_load),
        .w_bank(w_bank), .w_col_idx(w_col_idx), .w_col(w_col),
        .bias_line(bias_line_r), .mc_line(mc_line_r),
        .rd_req(rd_req), .rd_req_addr(rd_req_addr), .rd_req_len(rd_req_len),
        .rd_data(rd_data_r), .rd_valid(rd_valid_r), .rd_ready(rd_ready),
        .wr_req(wr_req), .wr_req_addr(wr_req_addr), .wr_req_len(wr_req_len),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(1'b1),
        .busy_o(busy_o), .done_o(done_o),
        .dbg_state(dbg_state), .dbg_x(dbg_x), .dbg_y(dbg_y)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- M2 读服务器 ----------------
    reg [31:0] rd_addr_r;
    reg [15:0] rd_beats_left;
    reg [15:0] rd_req_beats;

    function [127:0] beat_at;
        input [31:0] a;
        begin
            beat_at = {ddr[a+15], ddr[a+14], ddr[a+13], ddr[a+12],
                       ddr[a+11], ddr[a+10], ddr[a+9],  ddr[a+8],
                       ddr[a+7],  ddr[a+6],  ddr[a+5],  ddr[a+4],
                       ddr[a+3],  ddr[a+2],  ddr[a+1],  ddr[a]};
        end
    endfunction

    always @(posedge aclk) begin
        if (!rst_n) begin
            rd_valid_r    <= 1'b0;
            rd_beats_left <= 16'd0;
        end else begin
            if (rd_valid_r && rd_ready) begin
                rd_addr_r     <= rd_addr_r + 32'd16;
                rd_beats_left <= rd_beats_left - 16'd1;
                if (rd_beats_left <= 16'd1) begin
                    rd_valid_r <= 1'b0;
                end else begin
                    rd_data_r <= beat_at(rd_addr_r + 32'd16);
                end
            end
            if (rd_req) begin
                rd_addr_r     <= rd_req_addr;
                rd_beats_left <= rd_req_beats;
                rd_data_r     <= beat_at(rd_req_addr);
                rd_valid_r    <= 1'b1;
                if (dbg_en)
                    $display("[SRV] t=%0t req addr=%08h c_cur=%0d r_cur=%0d b0=%02h b1=%02h",
                             $time, rd_req_addr, u_dut.c_cur, u_dut.r_cur,
                             ddr[rd_req_addr], ddr[rd_req_addr+1]);
            end
        end
    end

    // ---------------- M2 写服务器 ----------------
    reg [31:0] wr_addr_r;
    always @(posedge aclk) begin
        if (wr_req)
            wr_addr_r <= wr_req_addr;
        if (wr_valid) begin
            ddr[wr_addr_r+0]  <= wr_data[7:0];
            ddr[wr_addr_r+1]  <= wr_data[15:8];
            ddr[wr_addr_r+2]  <= wr_data[23:16];
            ddr[wr_addr_r+3]  <= wr_data[31:24];
            ddr[wr_addr_r+4]  <= wr_data[39:32];
            ddr[wr_addr_r+5]  <= wr_data[47:40];
            ddr[wr_addr_r+6]  <= wr_data[55:48];
            ddr[wr_addr_r+7]  <= wr_data[63:56];
            ddr[wr_addr_r+8]  <= wr_data[71:64];
            ddr[wr_addr_r+9]  <= wr_data[79:72];
            ddr[wr_addr_r+10] <= wr_data[87:80];
            ddr[wr_addr_r+11] <= wr_data[95:88];
            ddr[wr_addr_r+12] <= wr_data[103:96];
            ddr[wr_addr_r+13] <= wr_data[111:104];
            ddr[wr_addr_r+14] <= wr_data[119:112];
            ddr[wr_addr_r+15] <= wr_data[127:120];
            wr_addr_r <= wr_addr_r + 32'd16;
        end
    end

    // ---------------- 调试轨迹 ----------------
    always @(posedge aclk) begin
        if (dbg_en && u_dut.st == 3'd3 && u_dut.o_cur <= 1 && u_dut.ph_en &&
            (u_dut.ph <= 13'd16))
            $display("[DBG] o=%0d x=%0d ph=%0d ky=%0d kw=%0d cin=%0d bank0=%0d pix=%02h wL0=%02h",
                     u_dut.o_cur, u_dut.x_cur, u_dut.ph, u_dut.kyi, u_dut.kwi, u_dut.cini,
                     u_dut.bank0_cnt, u_dut.lb_rd_data, u_dut.w_col[7:0]);
    end

    // ---------------- 公共任务（文件名参数化, 相对 sim/modelsim/） ----------------
    task load_wmem;
        input [8*32-1:0] fname;
        begin
            for (i = 0; i < 1024; i = i + 1) wmem[i] = 2048'd0;
            $readmemh(fname, wmem);
        end
    endtask

    task load_bias_mc;
        input [8*32-1:0] fbias;
        input [8*32-1:0] fmc;
        begin
            for (i = 0; i < CHM; i = i + 1) begin
                bias_arr[i] = 32'd0;
                mc_arr[i]   = 32'd0;
            end
            $readmemh(fbias, bias_arr);
            $readmemh(fmc,   mc_arr);
            for (i = 0; i < CHM; i = i + 1) begin
                bias_line[i*32 +: 32] = bias_arr[i];
                mc_line[i*32 +: 32]   = mc_arr[i];
            end
        end
    endtask

    task load_input;
        input [8*32-1:0] fname;
        input integer W, H, C;
        begin
            for (i = 0; i < 1024; i = i + 1) inrow[i] = 128'd0;
            $readmemh(fname, inrow);
            for (c = 0; c < C; c = c + 1)
                for (y = 0; y < H; y = y + 1)
                    for (x = 0; x < W; x = x + 1)
                        ddr[RD_BASE + (c*H + y)*W + x] =
                            inrow[c*H + y][(W-1-x)*8 +: 8];   // 低 lane = 低地址
        end
    endtask

    task load_exp;
        input [8*32-1:0] fname;
        begin
            for (i = 0; i < 65536; i = i + 1) exp_arr[i] = 8'h00;
            $readmemh(fname, exp_arr);
        end
    endtask

    task check_out;
        input integer W, H, C;
        input [8*16-1:0] tag;
        integer nerr, rowerr;
        begin
            nerr = 0;
            idx  = 0;
            for (c = 0; c < C; c = c + 1) begin
                rowerr = 0;
                for (y = 0; y < H; y = y + 1) begin
                    for (x = 0; x < W; x = x + 1) begin
                        if (ddr[WR_BASE + c*H*W + y*W + x] !== exp_arr[idx]) begin
                            if (nerr < 8)
                                $display("[FAIL] %0s c=%0d y=%0d x=%0d got=%02h exp=%02h",
                                         tag, c, y, x, ddr[WR_BASE + c*H*W + y*W + x],
                                         exp_arr[idx]);
                            nerr = nerr + 1;
                            rowerr = rowerr + 1;
                        end
                        idx = idx + 1;
                    end
                    if (rowerr != 0)
                        $display("  [map] %0s c=%0d y=%0d: %0d/%0d bad", tag, c, y, rowerr, W);
                    rowerr = 0;
                end
            end
            if (nerr != 0) begin
                $display("[FAIL] %0s: %0d/%0d bytes mismatched", tag, nerr, C*H*W);
                err_cnt = err_cnt + nerr;
            end else
                $display("[ ok ] %0s: %0d bytes all match", tag, C*H*W);
        end
    endtask

    task run_one;
        input [8*16-1:0] tag;
        input integer W, H, CI, CO;
        input [8*32-1:0] fw, fb, fm, fin, fex;
        begin
            $display("=== %0s: W=%0d H=%0d C_in=%0d out_ch=%0d ===", tag, W, H, CI, CO);
            for (i = 0; i < 65536; i = i + 1) ddr[i] = 8'h00;
            load_wmem(fw);
            load_bias_mc(fb, fm);
            load_input(fin, W, H, CI);
            load_exp(fex);
            cfg_in_ch <= CI[6:0];  cfg_out_ch <= CO[6:0];
            cfg_w <= W[10:0];  cfg_h <= H[10:0];
            rd_req_beats = W / 16;
            @(posedge aclk);
            cfg_load <= 1'b1;
            @(posedge aclk);
            cfg_load <= 1'b0;
            wait (done_o === 1'b1);
            repeat (2) @(posedge aclk);
            check_out(W, H, CO, tag);
        end
    endtask

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        dbg_en  = 1'b0;          // 调试轨迹开关(需观察时置 1)
        rst_n = 1'b0;
        cfg_load = 1'b0;  cfg_relu_en = 1'b1;  cfg_bank_id = 4'd0;
        cfg_rd_base = RD_BASE;  cfg_wr_base = WR_BASE;
        cfg_in_ch = 7'd0;  cfg_out_ch = 7'd0;  cfg_w = 11'd0;  cfg_h = 11'd0;
        for (i = 0; i < 131072; i = i + 1) ddr[i] = 8'h00;
        bias_line = 0;  mc_line = 0;
        rd_data_r = 0;  rd_valid_r = 0;  rd_req_beats = 1;
        rd_addr_r = 0;  rd_beats_left = 0;  wr_addr_r = 0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        run_one("T0", 16, 6, 3, 4,
                "../vec/t0_wcol.hex", "../vec/t0_bias.hex", "../vec/t0_mc.hex",
                "../vec/t0_in.hex",   "../vec/t0_exp.hex");
        run_one("T1", 16, 6, 3, 4,
                "../vec/t1_wcol.hex", "../vec/t1_bias.hex", "../vec/t1_mc.hex",
                "../vec/t1_in.hex",   "../vec/t1_exp.hex");
        run_one("T2", 16, 6, 3, 16,
                "../vec/t2_wcol.hex", "../vec/t2_bias.hex", "../vec/t2_mc.hex",
                "../vec/t2_in.hex",   "../vec/t2_exp.hex");

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #5_000_000;
        $display("TB FAIL (timeout)  state=%0d x=%0d y=%0d", dbg_state, dbg_x, dbg_y);
        $finish;
    end

endmodule
