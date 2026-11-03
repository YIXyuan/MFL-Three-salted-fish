// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_line_buffer_v1_0.v
// Description : kosmo2_line_buffer_v1_0 自校验 testbench（M3）
//   * 金模型: ref_mem[(c*H+y)*W+x] 按图存参考图, gold() 计算含 padding 的窗口期望值
//   * T1: W=8,C=2,H=5 全窗口穷举(列/行 padding 全覆盖, 5*8*3*3*2 = 720 读)
//   * T2: 背靠背流水读(固定 2 拍延迟对齐, 60 拍连续)
//   * T3: 装入与开窗并发(读 bank0 同时装 bank2, 验证 SDP 无串扰)
//   * T4: 换层配置(W=3,C=1,H=2) 重新穷举
//   结束打印 TB PASS / TB FAIL
// 运行        : python tools/run_sim.py --ip ip/kosmo2_line_buffer --do sim_line_buffer.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_line_buffer_v1_0;

    localparam integer W = 8, C = 2, H = 5;

    reg         aclk;
    reg         rst_n;
    reg  [9:0]  cfg_w;
    reg  [6:0]  cfg_c;
    reg         cfg_load;
    reg         ld_start;
    reg  [1:0]  ld_bank;
    reg  [6:0]  ld_ch;
    reg         ld_valid;
    wire        ld_ready;
    reg  [7:0]  ld_data;
    wire        ld_done;
    reg         rd_valid;
    reg  [1:0]  rd_bank0;
    reg  [2:0]  rd_row_ok;
    reg  [1:0]  rd_ky, rd_kw;
    reg  [6:0]  rd_cin;
    reg  [9:0]  rd_x;
    wire [7:0]  rd_data;
    wire        rd_data_vld;
    wire [1:0]  dbg_bank;

    integer err_cnt;
    integer i, o, x, ky, kw, cin, b0, kyi;
    reg [7:0] d;
    reg dbg_en;                              // 调试打印开关(默认关)

    // 金模型参考图
    reg [7:0] ref_mem [0:W*H*C-1];

    kosmo2_line_buffer_v1_0 #(
        .C_ROW_BYTES (16384),
        .C_CH_BITS   (7),
        .C_X_BITS    (10)
    ) u_dut (
        .aclk        (aclk),
        .rst_n       (rst_n),
        .cfg_w       (cfg_w),
        .cfg_c       (cfg_c),
        .cfg_load    (cfg_load),
        .ld_start    (ld_start),
        .ld_bank     (ld_bank),
        .ld_ch       (ld_ch),
        .ld_valid    (ld_valid),
        .ld_ready    (ld_ready),
        .ld_data     (ld_data),
        .ld_done     (ld_done),
        .rd_valid    (rd_valid),
        .rd_bank0    (rd_bank0),
        .rd_row_ok   (rd_row_ok),
        .rd_ky       (rd_ky),
        .rd_kw       (rd_kw),
        .rd_cin      (rd_cin),
        .rd_x        (rd_x),
        .rd_data     (rd_data),
        .rd_data_vld (rd_data_vld),
        .dbg_bank    (dbg_bank)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // 金模型: 含行/列 padding 的窗口期望值
    function [7:0] gold;
        input integer cin_i;
        input integer y_abs;
        input integer x_abs;
        input integer h_cur;
        input integer w_cur;
        begin
            if (y_abs < 0 || y_abs >= h_cur)      gold = 8'h00;
            else if (x_abs < 0 || x_abs >= w_cur) gold = 8'h00;
            else                                  gold = ref_mem[(cin_i*h_cur + y_abs)*w_cur + x_abs];
        end
    endfunction

    // 调试: DUT 实际采样观测
    always @(posedge aclk) begin
        if (dbg_en && rd_valid)
            $display("[DBG-S0] t=%0t bank0=%0d ky=%0d kw=%0d cin=%0d x=%0d rok=%b",
                     $time, rd_bank0, rd_ky, rd_kw, rd_cin, rd_x, rd_row_ok);
        if (dbg_en && u_dut.s1_v)
            $display("[DBG-S1] t=%0t s1_bank=%0d s1_addr=%0d s1_pad=%b",
                     $time, u_dut.s1_bank, u_dut.s1_addr, u_dut.s1_pad);
    end

    // ---------------- 任务 ----------------
    // 装入某通道的一行(w_cur 字节顺序流, bank=y%3)
    task ld_row;
        input integer ch;
        input integer y;
        input integer w_cur;
        input integer h_cur;
        integer k;
        begin
            @(posedge aclk);
            ld_start <= 1'b1;
            ld_bank  <= y % 3;
            ld_ch    <= ch[6:0];
            @(posedge aclk);
            ld_start <= 1'b0;
            for (k = 0; k < w_cur; k = k + 1) begin
                ld_data  <= ref_mem[(ch*h_cur + y)*w_cur + k];
                ld_valid <= 1'b1;
                @(posedge aclk);
            end
            ld_valid <= 1'b0;
            @(posedge aclk);
            if (ld_done !== 1'b1) begin
                $display("[FAIL] ld_done missing (ch=%0d y=%0d)", ch, y);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // 单次窗口读(地址拍 + 固定 2 拍延迟取数)
    task win_read;
        input integer ky_i;
        input integer kw_i;
        input integer cin_i;
        input integer x_i;
        input integer o_i;
        input integer h_cur;
        input integer w_cur;
        output [7:0]  d_o;
        begin
            b0 = (((o_i - 1) % 3) + 3) % 3;
            rd_row_ok = 3'b000;
            for (kyi = 0; kyi < 3; kyi = kyi + 1)
                if (o_i - 1 + kyi >= 0 && o_i - 1 + kyi < h_cur)
                    rd_row_ok[kyi] = 1'b1;
            @(posedge aclk);
            rd_bank0 <= b0[1:0];
            rd_ky    <= ky_i[1:0];
            rd_kw    <= kw_i[1:0];
            rd_cin   <= cin_i[6:0];
            rd_x     <= x_i[9:0];
            rd_valid <= 1'b1;
            @(posedge aclk);
            rd_valid <= 1'b0;
            @(posedge aclk);
            @(posedge aclk);
            if (rd_data_vld !== 1'b1) begin
                $display("[FAIL] rd_data_vld missing (o=%0d x=%0d ky=%0d kw=%0d cin=%0d)",
                         o_i, x_i, ky_i, kw_i, cin_i);
                err_cnt = err_cnt + 1;
            end
            d_o = rd_data;
        end
    endtask

    // 流水读采集(背靠背测试用)
    reg [7:0] exp_q [0:127];
    reg [7:0] got_q [0:127];
    integer n_exp, n_got;
    always @(posedge aclk) begin
        if (rst_n && rd_data_vld) begin
            got_q[n_got] = rd_data;
            n_got = n_got + 1;
        end
    end

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt   = 0;
        dbg_en    = 1'b0;
        cfg_w     = 10'd8;
        cfg_c     = 7'd2;
        cfg_load  = 1'b0;
        ld_start  = 1'b0;
        ld_valid  = 1'b0;
        ld_data   = 8'h0;
        rd_valid  = 1'b0;
        rd_row_ok = 3'b000;
        rst_n     = 1'b0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        // 参考图
        for (i = 0; i < W*H*C; i = i + 1)
            ref_mem[i] = (i * 7 + 13) & 8'hff;

        $display("=== T1: W=8 C=2 H=5 全窗口穷举(含 padding) ===");
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        // 预装 y=0,1 两行(每图像行 C 个通道行)
        ld_row(0, 0, W, H);  ld_row(1, 0, W, H);
        ld_row(0, 1, W, H);  ld_row(1, 1, W, H);
        for (o = 0; o < H; o = o + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                for (ky = 0; ky < 3; ky = ky + 1) begin
                    for (kw = 0; kw < 3; kw = kw + 1) begin
                        for (cin = 0; cin < C; cin = cin + 1) begin
                            win_read(ky, kw, cin, x, o, H, W, d);
                            if (d !== gold(cin, o - 1 + ky, x + kw - 1, H, W)) begin
                                if (err_cnt < 8)
                                    $display("[FAIL] o=%0d x=%0d ky=%0d kw=%0d cin=%0d got=%02h exp=%02h",
                                             o, x, ky, kw, cin, d,
                                             gold(cin, o - 1 + ky, x + kw - 1, H, W));
                                err_cnt = err_cnt + 1;
                            end
                        end
                    end
                end
            end
            if (o + 2 < H) begin                 // 装 y=o+2 供下一窗(不超出图像行数)
                ld_row(0, o + 2, W, H);
                ld_row(1, o + 2, W, H);
            end
        end

        $display("=== T2: 背靠背流水读(60 拍连续, 2 拍延迟对齐) ===");
        n_exp = 0;  n_got = 0;
        @(posedge aclk);
        for (i = 0; i < 60; i = i + 1) begin
            ky  = (i / 6) % 3;
            kw  = i % 3;
            cin = (i / 2) % 2;
            x   = (i * 3) % W;
            o   = 3;
            b0  = (((o - 1) % 3) + 3) % 3;
            rd_row_ok = 3'b000;
            for (kyi = 0; kyi < 3; kyi = kyi + 1)
                if (o - 1 + kyi >= 0 && o - 1 + kyi < H) rd_row_ok[kyi] = 1'b1;
            rd_bank0 <= b0[1:0];
            rd_ky    <= ky[1:0];
            rd_kw    <= kw[1:0];
            rd_cin   <= cin[6:0];
            rd_x     <= x[9:0];
            rd_valid <= 1'b1;
            exp_q[n_exp] = gold(cin, o - 1 + ky, x + kw - 1, H, W);
            n_exp = n_exp + 1;
            @(posedge aclk);
        end
        rd_valid <= 1'b0;
        repeat (6) @(posedge aclk);
        if (n_got !== n_exp) begin
            $display("[FAIL] pipeline beats got=%0d exp=%0d", n_got, n_exp);
            err_cnt = err_cnt + 1;
        end
        for (i = 0; i < n_exp && i < 128; i = i + 1) begin
            if (got_q[i] !== exp_q[i]) begin
                if (err_cnt < 16)
                    $display("[FAIL] pipeline #%0d got=%02h exp=%02h", i, got_q[i], exp_q[i]);
                err_cnt = err_cnt + 1;
            end
        end

        $display("=== T3: 装入(bank2) 与 开窗(读 bank0) 并发 ===");
        n_exp = 0;  n_got = 0;
        fork
            begin : ld_bg
                // 向 bank2 装入"虚拟行 y=5"(覆盖 y=2 旧数据, 此时已无人读)
                // 注意: 两分支不得共用循环变量(曾因共享 i 导致装入错乱)
                integer k2;
                begin
                    @(posedge aclk);
                    ld_start <= 1'b1;  ld_bank <= 2'd2;  ld_ch <= 7'd0;
                    @(posedge aclk);
                    ld_start <= 1'b0;
                    for (k2 = 0; k2 < W; k2 = k2 + 1) begin
                        ld_data  <= 8'hA0 + k2;
                        ld_valid <= 1'b1;
                        @(posedge aclk);
                    end
                    ld_valid <= 1'b0;
                end
            end
            begin : rd_bg
                // 同时连续读 bank0(ky=0, bank0=0) —— 不受装入影响
                integer k3;
                begin
                    for (k3 = 0; k3 < 16; k3 = k3 + 1) begin
                        rd_bank0 <= 2'd0;
                        rd_row_ok <= 3'b111;
                        rd_ky <= 2'd0;  rd_kw <= 2'd1;
                        rd_cin <= 7'd0;
                        rd_x <= (k3 * 2) % W;
                        rd_valid <= 1'b1;
                        exp_q[n_exp] = gold(0, 3, (k3 * 2) % W, H, W);  // bank0 现存 y=3 行
                        n_exp = n_exp + 1;
                        @(posedge aclk);
                    end
                    rd_valid <= 1'b0;
                end
            end
        join
        repeat (6) @(posedge aclk);
        if (n_got !== n_exp) begin
            $display("[FAIL] concurrent reads got=%0d exp=%0d", n_got, n_exp);
            err_cnt = err_cnt + 1;
        end
        for (i = 0; i < n_exp && i < 128; i = i + 1) begin
            if (got_q[i] !== exp_q[i]) begin
                if (err_cnt < 24)
                    $display("[FAIL] concurrent #%0d got=%02h exp=%02h", i, got_q[i], exp_q[i]);
                err_cnt = err_cnt + 1;
            end
        end
        // 校验 bank2 新内容(直接读: bank0=2, ky=0)
        for (x = 0; x < W; x = x + 1) begin
            @(posedge aclk);
            rd_bank0 <= 2'd2;  rd_row_ok <= 3'b111;  rd_ky <= 2'd0;  rd_kw <= 2'd1;
            rd_cin <= 7'd0;    rd_x <= x[9:0];       rd_valid <= 1'b1;
            @(posedge aclk);
            rd_valid <= 1'b0;
            @(posedge aclk);
            @(posedge aclk);
            d = rd_data;
            if (d !== (8'hA0 + x[7:0])) begin
                $display("[FAIL] bank2 readback x=%0d got=%02h exp=%02h", x, d, 8'hA0 + x[7:0]);
                err_cnt = err_cnt + 1;
            end
        end

        $display("=== T4: 换层配置 W=3 C=1 H=2 重新穷举 ===");
        cfg_w <= 10'd3;
        cfg_c <= 7'd1;
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        // 重建参考图(新尺寸)
        for (i = 0; i < 3*2*1; i = i + 1)
            ref_mem[i] = (i * 11 + 5) & 8'hff;
        ld_row(0, 0, 3, 2);
        ld_row(0, 1, 3, 2);
        for (o = 0; o < 2; o = o + 1) begin
            for (x = 0; x < 3; x = x + 1) begin
                for (ky = 0; ky < 3; ky = ky + 1) begin
                    for (kw = 0; kw < 3; kw = kw + 1) begin
                        win_read(ky, kw, 0, x, o, 2, 3, d);
                        if (d !== gold(0, o - 1 + ky, x + kw - 1, 2, 3)) begin
                            if (err_cnt < 32)
                                $display("[FAIL] T4 o=%0d x=%0d ky=%0d kw=%0d got=%02h exp=%02h",
                                         o, x, ky, kw, d, gold(0, o - 1 + ky, x + kw - 1, 2, 3));
                            err_cnt = err_cnt + 1;
                        end
                    end
                end
            end
        end

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #1_000_000;
        $display("TB FAIL (timeout)");
        $finish;
    end

endmodule
