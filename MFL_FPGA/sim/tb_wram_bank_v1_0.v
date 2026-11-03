// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_wram_bank_v1_0.v
// Description : kosmo2_wram_bank_v1_0 自校验 testbench（M7）
//
//   测试组:
//   T1  逐层读回: 10 个 bank × 每个列号 t, 读回 w_col 与 .mem 生成源逐字节相等;
//       bias_line/mc_line 整行逐 lane 相等 + out_ch 以外补零断言;
//       CRC32 与 tools/gen_m7_wram.py 写入的 convXX_crc.hex 相等
//   T2  时序: 权重列号采样后恰好 2 拍出数（1 拍时必须仍是旧值）;
//       bank 切换后 2 拍内权重/整行参数正确
//   T3  抽查: convXX_spot.hex 的 16 个 (t,c) 由生成器直接按 npy 原始下标算出,
//       TB 重新寻址该列并比对（独立于列变换路径）
//   T4  M6 联仿: 真实 conv00/conv01 patch 经 M7 ROM -> M6 卷积引擎 -> NCHW 输出,
//       逐字节对拍（验证 HANDOFF §5.6 接口在实际链路上的时序）
//
//   向量/初始化文件由 tools/gen_m7_wram.py 生成（禁止手抄）
//   运行: python tools/run_sim.py --ip ip/kosmo2_wram_bank
//           --with ip/kosmo2_pe_layer --with ip/kosmo2_line_buffer
//           --with ip/kosmo2_mac_array --with ip/kosmo2_requant --do sim_wram_bank.do
//   Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_wram_bank_v1_0;

    localparam integer MAXDEPTH = 864;
    localparam [31:0]  RD_BASE  = 32'h0000_1000;
    localparam [31:0]  WR_BASE  = 32'h0000_4000;

    reg             aclk, rst_n;
    reg  [3:0]      bank_tb;
    reg  [9:0]      idx_tb;
    reg             joint_mode;

    wire [3:0]      w_bank;
    wire [9:0]      w_col_idx;
    wire [2047:0]   w_col;
    wire [8191:0]   bias_line, mc_line;

    // ---------------- M6 联仿信号 ----------------
    reg  [6:0]      cfg_in_ch, cfg_out_ch;
    reg  [10:0]     cfg_w, cfg_h;
    reg  [3:0]      cfg_bank_id;
    reg             cfg_relu_en;
    reg  [31:0]     cfg_rd_base, cfg_wr_base;
    reg             cfg_load;
    wire [3:0]      m6_bank;
    wire [9:0]      m6_colidx;
    wire            m6_rd_req, m6_rd_ready;
    wire [31:0]     m6_rd_addr;
    wire [10:0]     m6_rd_len;
    wire            m6_wr_req, m6_wr_valid;
    wire [31:0]     m6_wr_addr;
    wire [10:0]     m6_wr_len;
    wire [127:0]    m6_wr_data;
    wire            m6_busy, m6_done;
    wire [2:0]      m6_state;
    wire [10:0]     m6_dbgx, m6_dbgy;

    // M2 读服务器寄存器（必须先于实例声明）
    reg [31:0]      rd_addr_r;
    reg [15:0]      rd_beats_left;
    reg [127:0]     rd_data_r;
    reg             rd_valid_r;
    reg [31:0]      wr_addr_r;

    assign w_bank    = joint_mode ? m6_bank   : bank_tb;
    assign w_col_idx = joint_mode ? m6_colidx : idx_tb;

    // ---------------- DUT: M7 ----------------
    kosmo2_wram_bank_v1_0 u_dut (
        .aclk      (aclk),
        .rst_n     (rst_n),
        .w_bank    (w_bank),
        .w_col_idx (w_col_idx),
        .w_col     (w_col),
        .bias_line (bias_line),
        .mc_line   (mc_line)
    );

    // ---------------- DUT2: M6 (联仿) ----------------
    kosmo2_pe_layer_v1_0 #(
        .C_CH_MAX(96), .C_X_BITS(11), .C_ROW_BYTES(16384)
    ) u_pe (
        .aclk(aclk), .rst_n(rst_n),
        .cfg_in_ch(cfg_in_ch), .cfg_out_ch(cfg_out_ch),
        .cfg_w(cfg_w), .cfg_h(cfg_h),
        .cfg_bank_id(cfg_bank_id), .cfg_relu_en(cfg_relu_en),
        .cfg_rd_base(cfg_rd_base), .cfg_wr_base(cfg_wr_base),
        .cfg_load(cfg_load),
        .w_bank(m6_bank), .w_col_idx(m6_colidx), .w_col(w_col),
        .bias_line(bias_line), .mc_line(mc_line),
        .rd_req(m6_rd_req), .rd_req_addr(m6_rd_addr), .rd_req_len(m6_rd_len),
        .rd_data(rd_data_r), .rd_valid(rd_valid_r), .rd_ready(m6_rd_ready),
        .wr_req(m6_wr_req), .wr_req_addr(m6_wr_addr), .wr_req_len(m6_wr_len),
        .wr_data(m6_wr_data), .wr_valid(m6_wr_valid), .wr_ready(1'b1),
        .busy_o(m6_busy), .done_o(m6_done),
        .dbg_state(m6_state), .dbg_x(m6_dbgx), .dbg_y(m6_dbgy)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- 存储模型 ----------------
    reg [7:0]       ddr [0:131071];
    reg [767:0]     gold_w [0:MAXDEPTH-1];
    reg [3071:0]    gold_b [0:1];
    reg [3071:0]    gold_m [0:1];
    reg [31:0]      crc_exp [0:2];
    reg [31:0]      spot [0:15];
    reg [31:0]      crc_tab [0:255];
    reg [127:0]     inrow [0:8191];
    reg [7:0]       exp_arr [0:65535];

    integer err_cnt;
    integer i, j;
    reg     dbg_on;

    // ---------------- 调试轨迹: 对齐 M3/M7 的 2 拍数据（ph_en 拍） ----------------
    reg [1:0]  dky1, dky2, dkw1, dkw2;
    reg [6:0]  dci1, dci2;
    reg [12:0] dph1, dph2;
    always @(posedge aclk) begin
        dky1 <= u_pe.kyi;   dky2 <= dky1;
        dkw1 <= u_pe.kwi;   dkw2 <= dkw1;
        dci1 <= u_pe.cini;  dci2 <= dci1;
        dph1 <= u_pe.ph;    dph2 <= dph1;
    end
    always @(posedge aclk) begin
        if (dbg_on && u_pe.st == 3'd3 && u_pe.o_cur == 0 && u_pe.x_cur == 0 && u_pe.ph_en)
            $display("[D] ph=%0d dph=%0d ky=%0d kw=%0d cin=%0d pix=%02h w0=%02h w1=%02h",
                     u_pe.ph, dph2, dky2, dkw2, dci2,
                     u_pe.lb_rd_data, w_col[7:0], w_col[15:8]);
    end

    // ---------------- CRC32 (反射多项式 0xEDB88320, 与 zlib.crc32 一致) ----------------
    reg [31:0] tc;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            tc = i[31:0];
            for (j = 0; j < 8; j = j + 1)
                tc = tc[0] ? ((tc >> 1) ^ 32'hEDB88320) : (tc >> 1);
            crc_tab[i] = tc;
        end
    end

    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  b;
        begin
            crc_byte = (c >> 8) ^ crc_tab[(c ^ {24'd0, b}) & 32'hFF];
        end
    endfunction

    // ---------------- 每层形状（与 gen_m7_wram.py / quant_export 一致） ----------------
    function integer depth_of;
        input integer li;
        begin
            case (li)
                0:       depth_of = 27;
                1, 2:    depth_of = 144;
                3, 4:    depth_of = 288;
                5, 6:    depth_of = 576;
                default: depth_of = 864;
            endcase
        end
    endfunction

    function integer och_of;
        input integer li;
        begin
            case (li)
                0, 1:    och_of = 16;
                2, 3:    och_of = 32;
                4, 5:    och_of = 64;
                default: och_of = 96;
            endcase
        end
    endfunction

    // ---------------- 向量装载 ----------------
    task load_gold;
        input integer li;
        reg [8*40-1:0] fn;
        integer k;
        begin
            for (k = 0; k < MAXDEPTH; k = k + 1) gold_w[k] = 768'd0;
            gold_b[0] = 3072'd0;  gold_m[0] = 3072'd0;
            $sformat(fn, "../../mem/conv0%0d_w.mem", li);
            $readmemh(fn, gold_w);
            $sformat(fn, "../../mem/conv0%0d_b.mem", li);
            $readmemh(fn, gold_b);
            $sformat(fn, "../../mem/conv0%0d_mc.mem", li);
            $readmemh(fn, gold_m);
            $sformat(fn, "../../mem/conv0%0d_crc.hex", li);
            $readmemh(fn, crc_exp);
            for (k = 0; k < 16; k = k + 1) spot[k] = 32'd0;
            $sformat(fn, "../../mem/conv0%0d_spot.hex", li);
            $readmemh(fn, spot);
        end
    endtask

    task load_input;
        input [8*32-1:0] fname;
        input integer W, H, C;
        integer c, y, b, j, k;
        begin
            // 输入文件格式: 每行 16 字节(128bit), 次序 (c, y, beat)
            // 行内字节 x=beat*16+j 在字的最高字节起 (j=0 -> bit127)
            for (k = 0; k < 8192; k = k + 1) inrow[k] = 128'd0;
            $readmemh(fname, inrow);
            k = 0;
            for (c = 0; c < C; c = c + 1)
                for (y = 0; y < H; y = y + 1)
                    for (b = 0; b < W/16; b = b + 1) begin
                        for (j = 0; j < 16; j = j + 1)
                            ddr[RD_BASE + (c*H + y)*W + b*16 + j] =
                                inrow[k][(15-j)*8 +: 8];
                        k = k + 1;
                    end
        end
    endtask

    task load_exp;
        input [8*32-1:0] fname;
        begin
            for (i = 0; i < 65536; i = i + 1) exp_arr[i] = 8'h00;
            $readmemh(fname, exp_arr);
        end
    endtask

    // ---------------- T1: 整行 bias/Mc + 补零 ----------------
    task check_bias_mc;
        input integer och;
        input [8*16-1:0] tag;
        integer c, bad;
        begin
            bad = 0;
            for (c = 0; c < 256; c = c + 1) begin
                if (c < och) begin
                    if (bias_line[c*32 +: 32] !== gold_b[0][c*32 +: 32]) bad = bad + 1;
                    if (mc_line[c*32 +: 32]   !== gold_m[0][c*32 +: 32]) bad = bad + 1;
                end else begin
                    if (bias_line[c*32 +: 32] !== 32'd0) bad = bad + 1;
                    if (mc_line[c*32 +: 32]   !== 32'd0) bad = bad + 1;
                end
            end
            if (bad != 0) begin
                $display("[FAIL] %0s bias/mc lane errors=%0d (och=%0d)", tag, bad, och);
                err_cnt = err_cnt + bad;
            end else
                $display("[ ok ] %0s bias/mc rows + zero padding (%0d ch)", tag, och);
        end
    endtask

    // ---------------- T1: bias/Mc CRC ----------------
    task check_crc_bm;
        input integer och;
        input [8*16-1:0] tag;
        integer c;
        reg [31:0] cb, cm;
        begin
            cb = 32'hFFFFFFFF;
            cm = 32'hFFFFFFFF;
            for (c = 0; c < och; c = c + 1) begin
                cb = crc_byte(cb, bias_line[32*c +: 8]);
                cb = crc_byte(cb, bias_line[32*c+8 +: 8]);
                cb = crc_byte(cb, bias_line[32*c+16 +: 8]);
                cb = crc_byte(cb, bias_line[32*c+24 +: 8]);
                cm = crc_byte(cm, mc_line[32*c +: 8]);
                cm = crc_byte(cm, mc_line[32*c+8 +: 8]);
                cm = crc_byte(cm, mc_line[32*c+16 +: 8]);
                cm = crc_byte(cm, mc_line[32*c+24 +: 8]);
            end
            cb = ~cb;  cm = ~cm;
            if (cb !== crc_exp[1]) begin
                $display("[FAIL] %0s bias CRC got=%08h exp=%08h", tag, cb, crc_exp[1]);
                err_cnt = err_cnt + 1;
            end
            if (cm !== crc_exp[2]) begin
                $display("[FAIL] %0s mc CRC got=%08h exp=%08h", tag, cm, crc_exp[2]);
                err_cnt = err_cnt + 1;
            end
            if (cb === crc_exp[1] && cm === crc_exp[2])
                $display("[ ok ] %0s bias CRC=%08h mc CRC=%08h", tag, cb, cm);
        end
    endtask

    // ---------------- T1/T2: 逐列读回 + 2 拍延迟 ----------------
    task check_weights;
        input integer depth, och;
        input [8*16-1:0] tag;
        integer t, c, bad;
        reg [31:0] crc;
        reg [2047:0] expw;
        begin
            bad = 0;
            // 稳定值 t=0 -> t=depth-1: 1 拍时必须仍是旧值, 2 拍时为新值
            @(negedge aclk); idx_tb = 10'd0;
            repeat (2) @(posedge aclk);
            #1;
            expw = {1280'd0, gold_w[0]};
            if (w_col !== expw) begin
                $display("[FAIL] %0s pre-latency settle mismatch", tag);
                bad = bad + 1;
            end
            @(negedge aclk); idx_tb = depth - 1;
            @(posedge aclk);
            #1;
            if (w_col !== expw) begin
                $display("[FAIL] %0s latency: w_col changed after 1 cycle (exp old)", tag);
                bad = bad + 1;
            end
            @(posedge aclk);
            #1;
            expw = {1280'd0, gold_w[depth-1]};
            if (w_col !== expw) begin
                $display("[FAIL] %0s latency: w_col not updated after exactly 2 cycles", tag);
                bad = bad + 1;
            end
            // 全列逐字节读回 + CRC + 补零
            crc = 32'hFFFFFFFF;
            for (t = 0; t < depth; t = t + 1) begin
                @(negedge aclk); idx_tb = t[9:0];
                @(posedge aclk);
                @(posedge aclk);
                #1;
                expw = {1280'd0, gold_w[t]};
                if (w_col !== expw) begin
                    if (bad < 8) begin
                        $display("[FAIL] %0s t=%0d word mismatch", tag, t);
                        for (c = 0; c < och; c = c + 1)
                            if (w_col[8*c +: 8] !== gold_w[t][8*c +: 8])
                                $display("         lane c=%0d got=%02h exp=%02h",
                                         c, w_col[8*c +: 8], gold_w[t][8*c +: 8]);
                    end
                    bad = bad + 1;
                end
                for (c = och; c < 256; c = c + 1)
                    if (w_col[8*c +: 8] !== 8'h00) begin
                        if (bad < 8)
                            $display("[FAIL] %0s t=%0d pad lane c=%0d = %02h",
                                     tag, t, c, w_col[8*c +: 8]);
                        bad = bad + 1;
                    end
                for (c = 0; c < och; c = c + 1)
                    crc = crc_byte(crc, w_col[8*c +: 8]);
            end
            crc = ~crc;
            if (crc !== crc_exp[0]) begin
                $display("[FAIL] %0s weight CRC got=%08h exp=%08h", tag, crc, crc_exp[0]);
                bad = bad + 1;
            end
            if (bad == 0)
                $display("[ ok ] %0s %0d columns, CRC=%08h, latency=2, pad lanes 0",
                         tag, depth, crc);
            else
                $display("[FAIL] %0s total errors=%0d", tag, bad);
            err_cnt = err_cnt + bad;
        end
    endtask

    // ---------------- T3: 抽查 ----------------
    task check_spots;
        input integer depth, och;
        input [8*16-1:0] tag;
        integer k, t, c, bad;
        reg [31:0] sv;
        begin
            bad = 0;
            for (k = 0; k < 16; k = k + 1) begin
                sv = spot[k];
                t = sv[31:16];  c = sv[15:8];
                if (t >= depth || c >= och) begin
                    $display("[FAIL] %0s bad spot vector k=%0d t=%0d c=%0d", tag, k, t, c);
                    bad = bad + 1;
                end else begin
                    @(negedge aclk); idx_tb = t[9:0];
                    @(posedge aclk);
                    @(posedge aclk);
                    #1;
                    if (w_col[8*c +: 8] !== sv[7:0]) begin
                        $display("[FAIL] %0s spot t=%0d c=%0d got=%02h exp=%02h",
                                 tag, t, c, w_col[8*c +: 8], sv[7:0]);
                        bad = bad + 1;
                    end
                end
            end
            if (bad == 0) $display("[ ok ] %0s 16 spot checks", tag);
            err_cnt = err_cnt + bad;
        end
    endtask

    // ---------------- 一层全流程 ----------------
    task run_layer;
        input integer li;
        reg [8*16-1:0] tag;
        reg [2047:0] expw;
        begin
            $sformat(tag, "conv0%0d", li);
            load_gold(li);
            // bank 切换 + 2 拍内出数（T2 的 bank 切换断言）
            @(negedge aclk);
            bank_tb = li[3:0];  idx_tb = 10'd0;
            @(posedge aclk);
            @(posedge aclk);
            #1;
            expw = {1280'd0, gold_w[0]};
            if (w_col !== expw) begin
                $display("[FAIL] %0s bank-switch w_col(t=0) after 2 cycles", tag);
                err_cnt = err_cnt + 1;
            end
            check_bias_mc(och_of(li), tag);
            check_crc_bm(och_of(li), tag);
            check_weights(depth_of(li), och_of(li), tag);
            check_spots(depth_of(li), och_of(li), tag);
        end
    endtask

    // ---------------- M2 读服务器（16B/拍） ----------------
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
            rd_addr_r     <= 32'd0;
        end else begin
            if (rd_valid_r && m6_rd_ready) begin
                rd_addr_r     <= rd_addr_r + 32'd16;
                rd_beats_left <= rd_beats_left - 16'd1;
                if (rd_beats_left <= 16'd1)
                    rd_valid_r <= 1'b0;
                else
                    rd_data_r <= beat_at(rd_addr_r + 32'd16);
            end
            if (m6_rd_req) begin
                rd_addr_r     <= m6_rd_addr;
                rd_beats_left <= {6'd0, m6_rd_len} >> 4;
                rd_data_r     <= beat_at(m6_rd_addr);
                rd_valid_r    <= 1'b1;
            end
        end
    end

    // ---------------- M2 写服务器 ----------------
    always @(posedge aclk) begin
        if (m6_wr_req)
            wr_addr_r <= m6_wr_addr;
        if (m6_wr_valid) begin
            ddr[wr_addr_r+0]  <= m6_wr_data[7:0];
            ddr[wr_addr_r+1]  <= m6_wr_data[15:8];
            ddr[wr_addr_r+2]  <= m6_wr_data[23:16];
            ddr[wr_addr_r+3]  <= m6_wr_data[31:24];
            ddr[wr_addr_r+4]  <= m6_wr_data[39:32];
            ddr[wr_addr_r+5]  <= m6_wr_data[47:40];
            ddr[wr_addr_r+6]  <= m6_wr_data[55:48];
            ddr[wr_addr_r+7]  <= m6_wr_data[63:56];
            ddr[wr_addr_r+8]  <= m6_wr_data[71:64];
            ddr[wr_addr_r+9]  <= m6_wr_data[79:72];
            ddr[wr_addr_r+10] <= m6_wr_data[87:80];
            ddr[wr_addr_r+11] <= m6_wr_data[95:88];
            ddr[wr_addr_r+12] <= m6_wr_data[103:96];
            ddr[wr_addr_r+13] <= m6_wr_data[111:104];
            ddr[wr_addr_r+14] <= m6_wr_data[119:112];
            ddr[wr_addr_r+15] <= m6_wr_data[127:120];
            wr_addr_r <= wr_addr_r + 32'd16;
        end
    end

    // ---------------- 输出对拍 ----------------
    task check_out;
        input integer W, H, C;
        input [8*16-1:0] tag;
        integer nerr, rowerr, idx, c, y, x;
        begin
            nerr = 0;  idx = 0;
            for (c = 0; c < C; c = c + 1) begin
                rowerr = 0;
                for (y = 0; y < H; y = y + 1) begin
                    for (x = 0; x < W; x = x + 1) begin
                        if (ddr[WR_BASE + c*H*W + y*W + x] !== exp_arr[idx]) begin
                            if (nerr < 8)
                                $display("[FAIL] %0s c=%0d y=%0d x=%0d got=%02h exp=%02h",
                                         tag, c, y, x,
                                         ddr[WR_BASE + c*H*W + y*W + x], exp_arr[idx]);
                            nerr = nerr + 1;  rowerr = rowerr + 1;
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

    // ---------------- T4: M6 联仿 ----------------
    task run_joint;
        input [8*16-1:0] tag;
        input integer W, H, CI, CO;
        input [3:0] bank;
        input [8*32-1:0] fin, fex;
        begin
            $display("=== %0s: M6+M7 real patch W=%0d H=%0d C_in=%0d out_ch=%0d bank=%0d ===",
                     tag, W, H, CI, CO, bank);
            joint_mode = 1'b1;
            for (i = 0; i < 131072; i = i + 1) ddr[i] = 8'h00;
            load_input(fin, W, H, CI);
            load_exp(fex);
            cfg_in_ch = CI[6:0];  cfg_out_ch = CO[6:0];
            cfg_w = W[10:0];       cfg_h = H[10:0];
            cfg_bank_id = bank;   cfg_relu_en = 1'b1;
            cfg_rd_base = RD_BASE; cfg_wr_base = WR_BASE;
            @(posedge aclk);
            cfg_load = 1'b1;
            @(posedge aclk);
            cfg_load = 1'b0;
            wait (m6_done === 1'b1);
            repeat (2) @(posedge aclk);
            check_out(W, H, CO, tag);
        end
    endtask

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        dbg_on = 1'b0;
        joint_mode = 1'b0;
        bank_tb = 4'd0;  idx_tb = 10'd0;
        rst_n = 1'b0;
        cfg_load = 1'b0;  cfg_relu_en = 1'b1;  cfg_bank_id = 4'd0;
        cfg_rd_base = RD_BASE;  cfg_wr_base = WR_BASE;
        cfg_in_ch = 7'd0;  cfg_out_ch = 7'd0;  cfg_w = 11'd0;  cfg_h = 11'd0;
        rd_data_r = 0;  rd_valid_r = 0;  rd_addr_r = 0;  rd_beats_left = 0;
        wr_addr_r = 0;
        for (i = 0; i < 131072; i = i + 1) ddr[i] = 8'h00;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        // ---- T1/T2/T3: 10 个 bank 逐层验证 ----
        for (i = 0; i < 10; i = i + 1)
            run_layer(i);

        // ---- T4: M6 联仿（真实 conv00 / conv01 patch）----
        run_joint("J0_conv00", 16, 6, 3, 16, 4'd0,
                  "../vec/joint0_in.hex", "../vec/joint0_exp.hex");
        run_joint("J1_conv01", 16, 6, 16, 16, 4'd1,
                  "../vec/joint1_in.hex", "../vec/joint1_exp.hex");
        run_joint("J2_conv00_w1024", 1024, 2, 3, 16, 4'd0,
                  "../vec/joint2_in.hex", "../vec/joint2_exp.hex");

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #20_000_000;
        $display("TB FAIL (timeout) state=%0d x=%0d y=%0d", m6_state, m6_dbgx, m6_dbgy);
        $finish;
    end

endmodule
