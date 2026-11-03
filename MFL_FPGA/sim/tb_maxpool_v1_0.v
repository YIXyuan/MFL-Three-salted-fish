// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_maxpool_v1_0.v
// Description : kosmo2_maxpool_v1_0 自校验 testbench（M5b）
//   * T1: W=8,C=4,H=6 随机图(含 -128/127), 整帧流+金模型比对(池化 3×4 段)
//   * T2: 随机反压(m_ready 随机 50%)
//   * T3: 奇数尺寸 W=7,H=5 → 调度器补 pad 像素/行(8'h80=-128), 金模型按 7×5
//     越界视为 -128, 验证有符号取大下负值像素正确胜过 pad
//     (详解稿"补 0"对负值像素是错的, 已按 -128 修正)
//   * T4: 全 -128 矩阵 → 输出全 0x80（有符号取大, 不是 0）
//   * T5: cfg_c=2 (< C_CH_MAX) 段高位恒 0
//   参考图布局: ref[(c*ref_h+y)*ref_w+x], gold 越界(≥ref_h/ref_w)视为 -128 pad
//   结束打印 TB PASS / TB FAIL
// 运行        : python tools/run_sim.py --ip ip/kosmo2_maxpool --do sim_maxpool.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_maxpool_v1_0;

    localparam integer CHM = 96;             // C_CH_MAX

    reg         aclk;
    reg         rst_n;
    reg  [9:0]  cfg_w, cfg_h;
    reg  [6:0]  cfg_c;
    reg         cfg_load;
    reg  [CHM*8-1:0] s_data;
    reg         s_valid;
    wire        s_ready;
    wire [CHM*8-1:0] m_data;
    wire        m_valid;
    reg         m_ready;
    wire [2:0]  dbg_state;

    integer err_cnt;
    integer i, x, y, c;
    reg dbg_en;

    // 参考图与尺寸
    reg [7:0] ref_mem [0:1023*96-1];
    integer   ref_h, ref_w;                  // 有效图尺寸(金模型越界=-128)
    integer   W_cur, H_cur, C_cur;           // 流内尺寸(已补 pad)与通道

    kosmo2_maxpool_v1_0 #(
        .C_CH_MAX    (CHM),
        .C_YBUF_WORDS(512),
        .C_X_BITS    (10)
    ) u_dut (
        .aclk     (aclk),
        .rst_n    (rst_n),
        .cfg_w    (cfg_w),
        .cfg_c    (cfg_c),
        .cfg_h    (cfg_h),
        .cfg_load (cfg_load),
        .s_data   (s_data),
        .s_valid  (s_valid),
        .s_ready  (s_ready),
        .m_data   (m_data),
        .m_valid  (m_valid),
        .m_ready  (m_ready),
        .dbg_state(dbg_state)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // 金模型: 池化输出段(y2,x2)某通道 —— 四位置有符号取大, 越界补 -128
    function [7:0] gold;
        input integer c_i;
        input integer y2;
        input integer x2;
        integer yy, xx, dy, dx;
        reg [7:0] m, v;
        begin
            m = 8'h80;
            for (dy = 0; dy < 2; dy = dy + 1) begin
                for (dx = 0; dx < 2; dx = dx + 1) begin
                    yy = y2*2 + dy;
                    xx = x2*2 + dx;
                    if (yy < ref_h && xx < ref_w) begin
                        v = ref_mem[(c_i*ref_h + yy)*ref_w + xx];
                        if ($signed(v) > $signed(m)) m = v;
                    end
                end
            end
            gold = m;
        end
    endfunction

    // 输出采集 + 比对（段内逐通道; x_out/y_out 跟踪池化像素位置）
    reg [7:0] exp_q [0:4095];
    reg [7:0] got_q [0:4095];
    integer n_exp, n_got;
    integer x_out, y_out;
    always @(posedge aclk) begin
        if (rst_n && m_valid && m_ready) begin
            for (c = 0; c < C_cur; c = c + 1) begin
                exp_q[n_exp] = gold(c, y_out, x_out);
                got_q[n_got] = m_data[c*8 +: 8];
                n_exp = n_exp + 1;
                n_got = n_got + 1;
            end
            for (c = C_cur; c < CHM; c = c + 1)              // 无效高位段恒 0
                if (m_data[c*8 +: 8] !== 8'h00) begin
                    if (err_cnt < 40) $display("[FAIL] high lane not zero");
                    err_cnt = err_cnt + 1;
                end
            x_out = x_out + 1;
            if (x_out == W_cur/2) begin
                x_out = 0;
                y_out = y_out + 1;
            end
        end
    end

    // 调试: 输入/输出握手时的 DUT 内部状态
    always @(posedge aclk) begin
        if (dbg_en)
            $display("[DBG-ST ] t=%0t state=%0d cfgload=%b sv=%b srdy=%b mv=%b mrdy=%b x2=%0d y=%0d",
                     $time, u_dut.state, cfg_load, s_valid, s_ready, m_valid, m_ready,
                     u_dut.x2_cnt, u_dut.y_cnt);
        if (dbg_en && s_valid && s_ready)
            $display("[DBG-IN ] t=%0t x2=%0d y=%0d rowodd=%b d=%02h",
                     $time, u_dut.x2_cnt, u_dut.y_cnt, u_dut.row_odd, s_data[7:0]);
        if (dbg_en && m_valid && m_ready)
            $display("[DBG-OUT] t=%0t x2=%0d y=%0d rowodd=%b d=%02h",
                     $time, u_dut.x2_cnt, u_dut.y_cnt, u_dut.row_odd, m_data[7:0]);
    end

    // 送一个像素段(握手直到 ready; pad 位置/通道填 8'h80)
    task send_px;
        input integer y_i;
        input integer x_i;
        input integer w_eff;
        begin
            for (c = 0; c < CHM; c = c + 1) begin
                if (c < C_cur && y_i < ref_h && x_i < w_eff)
                    s_data[c*8 +: 8] = ref_mem[(c*ref_h + y_i)*ref_w + x_i];
                else
                    s_data[c*8 +: 8] = 8'h80;
            end
            s_valid <= 1'b1;
            @(posedge aclk);
            while (!s_ready) @(posedge aclk);
            s_valid <= 1'b0;
            @(posedge aclk);
        end
    endtask

    // 整帧驱动 + 排空 + 比对
    task run_frame;
        input integer w_in;                  // 流内每行像素数(已含 pad)
        input integer h_in;                  // 流内行数(已含 pad)
        begin
            n_exp = 0;  n_got = 0;
            x_out = 0;  y_out = 0;
            for (y = 0; y < h_in; y = y + 1)
                for (x = 0; x < w_in; x = x + 1)
                    send_px(y, x, ref_w);
            repeat (64) @(posedge aclk);     // 排空
            if (n_got !== n_exp) begin
                $display("[FAIL] beats got=%0d exp=%0d", n_got, n_exp);
                err_cnt = err_cnt + 1;
            end
            for (i = 0; i < n_exp && i < 4096; i = i + 1) begin
                if (got_q[i] !== exp_q[i]) begin
                    if (err_cnt < 10)
                        $display("[FAIL] byte #%0d got=%02h exp=%02h", i, got_q[i], exp_q[i]);
                    err_cnt = err_cnt + 1;
                end
            end
        end
    endtask

    // m_ready 驱动器: bp_en=1 时随机反压, 否则常 1（唯一驱动源）
    reg     bp_en;
    integer bp_seed;
    always @(posedge aclk) begin
        if (!rst_n)            m_ready <= 1'b1;
        else if (bp_en)        m_ready <= (($random(bp_seed) % 2) == 0);
        else                   m_ready <= 1'b1;
    end

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        dbg_en  = 1'b1;
        bp_en   = 1'b0;
        bp_seed = 32'h504F_4F4C;
        cfg_load = 1'b0;
        s_valid  = 1'b0;
        s_data   = 0;
        rst_n    = 1'b0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: W=8 C=4 H=6 random (incl -128/127) ===");
        ref_h = 6;  ref_w = 8;  W_cur = 8;  H_cur = 6;  C_cur = 4;
        for (i = 0; i < 8*6*4; i = i + 1) begin
            case ($random % 4)
                0: ref_mem[i] = 8'h80;
                1: ref_mem[i] = 8'h7f;
                default: ref_mem[i] = $random;
            endcase
        end
        cfg_w <= 10'd8;  cfg_h <= 10'd6;  cfg_c <= 7'd4;
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        run_frame(8, 6);

        $display("=== T2: random backpressure ===");
        bp_en = 1'b1;
        run_frame(8, 6);
        bp_en = 1'b0;

        $display("=== T3: odd W=7 H=5, pad to 8x6 with -128 ===");
        ref_h = 5;  ref_w = 7;  W_cur = 8;  H_cur = 6;  C_cur = 4;
        for (i = 0; i < 7*5*4; i = i + 1) ref_mem[i] = $random;
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        run_frame(8, 6);

        $display("=== T4: all -128 matrix (signed-max sanity) ===");
        ref_h = 6;  ref_w = 8;  W_cur = 8;  H_cur = 6;  C_cur = 4;
        for (i = 0; i < 8*6*4; i = i + 1) ref_mem[i] = 8'h80;
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        n_exp = 0;  n_got = 0;  x_out = 0;  y_out = 0;
        for (y = 0; y < 6; y = y + 1)
            for (x = 0; x < 8; x = x + 1)
                send_px(y, x, 8);
        repeat (64) @(posedge aclk);
        if (n_got != n_exp) begin
            $display("[FAIL] T4 beats got=%0d exp=%0d", n_got, n_exp);
            err_cnt = err_cnt + 1;
        end
        for (i = 0; i < n_got && i < 4096; i = i + 1) begin
            if (got_q[i] !== 8'h80) begin
                $display("[FAIL] T4 signed-max broken: got=%02h exp=80", got_q[i]);
                err_cnt = err_cnt + 1;
                i = 4096;
            end
        end

        $display("=== T5: cfg_c=2, high lanes zero ===");
        ref_h = 6;  ref_w = 8;  W_cur = 8;  H_cur = 6;  C_cur = 2;
        for (i = 0; i < 8*6*2; i = i + 1) ref_mem[i] = $random;
        cfg_w <= 10'd8;  cfg_h <= 10'd6;  cfg_c <= 7'd2;
        cfg_load <= 1'b1;
        @(posedge aclk);
        cfg_load <= 1'b0;
        run_frame(8, 6);

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #2_000_000;
        $display("TB FAIL (timeout)");
        $finish;
    end

endmodule
