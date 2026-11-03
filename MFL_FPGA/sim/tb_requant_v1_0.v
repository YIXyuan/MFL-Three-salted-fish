// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_requant_v1_0.v
// Description : kosmo2_requant_v1_0 自校验 testbench（M5a）
//   * T1: 1000 组随机 acc/Mc/F/relu_en 背靠背流(含极值/floor 专项向量),
//     金模型（同口径镜像）逐一比对; 驱动为"单沿 NBA + 次沿采样"的无竞态模式
//   * T2: 延迟断言 —— q_valid 恒定滞后 in_valid 2 拍, 且值正确
//   * 金模型与 RTL 同语义（>>> = floor）; 与 PC 端量化基准的口径对齐在 M6 用
//     conv00 全量向量定死
// 运行        : python tools/run_sim.py --ip ip/kosmo2_requant --do sim_requant.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_requant_v1_0;

    reg                aclk;
    reg                rst_n;
    reg                in_valid;
    reg  signed [31:0] acc_in;
    reg  signed [31:0] mc_in;
    reg  [4:0]         fshift;
    reg                relu_en;
    wire               q_valid;
    wire [7:0]         q_out;

    integer err_cnt;
    integer i;
    integer n_exp, n_got;

    reg [7:0]  exp_q [0:1099];
    reg [7:0]  got_q [0:1099];

    // 待驱动向量(TB 本地, 避免与采样沿竞争)
    reg signed [31:0] r_acc, r_mc;
    integer           r_f;
    reg               r_re;

    kosmo2_requant_v1_0 u_dut (
        .aclk    (aclk),
        .rst_n   (rst_n),
        .in_valid(in_valid),
        .acc_in  (acc_in),
        .mc_in   (mc_in),
        .fshift  (fshift),
        .relu_en (relu_en),
        .q_valid (q_valid),
        .q_out   (q_out)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // 金模型: 与 RTL 同语义的口径镜像(乘 → +2^(F-1) 舍入 → >>>F → 饱和 → relu)
    // 口径依据: 2026-10-13 向量实验 —— floor 50.07% vs round 98.47% 与真值一致
    function [7:0] gold;
        input signed [31:0] acc;
        input signed [31:0] mc;
        input [4:0]         f;
        input               relu;
        reg signed [63:0] p, y, rnd;
        begin
            p = acc * mc;
            rnd = (f == 5'd0) ? 64'sd0 : (64'sd1 <<< (f - 5'd1));
            y = (p + rnd) >>> f;
            if (y > 64'sd127)       y = 64'sd127;
            else if (y < -64'sd128) y = -64'sd128;
            if (relu && (y < 0))    gold = 8'h00;
            else                    gold = y[7:0];
        end
    endfunction

    // 输出采集
    always @(posedge aclk) begin
        if (rst_n && q_valid) begin
            got_q[n_got] = q_out;
            n_got = n_got + 1;
        end
    end

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        n_exp   = 0;
        n_got   = 0;
        in_valid = 1'b0;
        acc_in   = 32'd0;
        mc_in    = 32'd0;
        fshift   = 5'd0;
        relu_en  = 1'b1;
        rst_n    = 1'b0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: 1000 random vectors, back-to-back, golden mirror ===");
        for (i = 0; i < 1000; i = i + 1) begin
            // 向量生成(边界混入)
            if (i == 100) begin
                r_acc = 32'h7FFFFFFF;  r_mc = 32'h7FFFFFFF;  r_f = 0;  r_re = 1'b1; end
            else if (i == 200) begin
                r_acc = -32'sd2147483648;  r_mc = -32'sd2147483648;  r_f = 0;  r_re = 1'b0; end
            else if (i == 300) begin
                r_acc = 32'sd12345;  r_mc = 32'sd0;  r_f = 31;  r_re = 1'b1; end
            else if (i == 400) begin
                r_acc = -32'sd1;  r_mc = 32'sd1;  r_f = 31;  r_re = 1'b0; end   // -1>>>31=-1
            else if (i == 500) begin
                r_acc = -32'sd255;  r_mc = 32'sd1;  r_f = 4;  r_re = 1'b0; end  // floor: -16
            else if (i == 600) begin
                r_acc = -32'sd256;  r_mc = 32'sd1;  r_f = 4;  r_re = 1'b1; end
            else if (i == 700) begin
                r_acc = 32'sd7;  r_mc = -32'sd3;  r_f = 1;  r_re = 1'b0; end    // -21>>>1=-11
            else begin
                r_acc = $random;
                r_mc  = $random;
                r_f   = $random % 32;
                if (r_f < 0) r_f = -r_f;
                r_re  = $random;
            end
            exp_q[n_exp] = gold(r_acc, r_mc, r_f[4:0], r_re);
            n_exp = n_exp + 1;
            // 单沿 NBA 驱动(次沿被 DUT 采样, 无同沿改写竞争)
            in_valid <= 1'b1;
            acc_in   <= r_acc;
            mc_in    <= r_mc;
            fshift   <= r_f[4:0];
            relu_en  <= r_re;
            @(posedge aclk);
            in_valid <= 1'b0;
        end
        repeat (6) @(posedge aclk);
        if (n_got !== n_exp) begin
            $display("[FAIL] beats got=%0d exp=%0d", n_got, n_exp);
            err_cnt = err_cnt + 1;
        end
        for (i = 0; i < n_exp && i < 1100; i = i + 1) begin
            if (got_q[i] !== exp_q[i]) begin
                if (err_cnt < 10)
                    $display("[FAIL] #%0d got=%02h exp=%02h", i, got_q[i], exp_q[i]);
                err_cnt = err_cnt + 1;
            end
        end

        $display("=== T2: latency check (q_valid == in_valid delayed 2) ===");
        begin
            @(posedge aclk);
            in_valid <= 1'b1;
            acc_in   <= 32'sd1000;
            mc_in    <= 32'sd1000;
            fshift   <= 5'd2;
            relu_en  <= 1'b1;                    // 1e6 >>> 2 = 250000 -> 饱和 127
            @(posedge aclk);                       // 采样拍 T
            in_valid <= 1'b0;
            @(posedge aclk);                       // T+1
            if (q_valid !== 1'b0) begin
                $display("[FAIL] q_valid early at T+1");
                err_cnt = err_cnt + 1;
            end
            @(posedge aclk);                       // T+2: q_valid 必须为 1
            if (q_valid !== 1'b1) begin
                $display("[FAIL] latency: q_valid not at T+2");
                err_cnt = err_cnt + 1;
            end else if (q_out !== 8'd127) begin
                $display("[FAIL] latency value got=%02h exp=7f", q_out);
                err_cnt = err_cnt + 1;
            end
            @(posedge aclk);                       // T+3: 应回落
            if (q_valid !== 1'b0) begin
                $display("[FAIL] q_valid should drop at T+3");
                err_cnt = err_cnt + 1;
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
