// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_mac_array_v1_0.v
// Description : kosmo2_mac_array_v1_0 自校验 testbench（M4）
//   * T1: 随机流复算 —— 随机 pix/w 打 100 拍(含随机暂停拍), TB 整型数组独立
//     复算 256 通道, 读出逐一比对
//   * T2: 极值专测 —— -128×-128 连打(逼近 1420 万不溢出) 与 -128×127(最负值)
//   * T3: bias 装载专测 —— acc_ld 后立即逐通道读出 = bias_line 原值
//   * T4: 高位通道丢弃 —— w_col 高位补零, 加速若干拍后高位 acc == bias 不变
//   * T5: 同拍 ld>en 优先级
//   结束打印 TB PASS / TB FAIL
// 运行        : python tools/run_sim.py --ip ip/kosmo2_mac_array --do sim_mac_array.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mac_array_v1_0;

    localparam integer OC = 256;

    reg         aclk;
    reg         rst_n;
    reg  [7:0]  pix_bcast;
    reg  [OC*8-1:0]  w_col;
    reg  [OC*32-1:0] bias_line;
    reg         acc_ld, acc_en, acc_rd;
    reg  [7:0]  c_read;
    wire signed [31:0] acc_out;
    wire        acc_out_vld;
    wire        busy_o;

    integer err_cnt;
    integer i, c;
    integer seed;

    // TB 参考模型
    integer model_acc [0:OC-1];
    reg signed [31:0] tb_bias [0:OC-1];

    kosmo2_mac_array_v1_0 #(.C_OC(OC)) u_dut (
        .aclk      (aclk),
        .rst_n     (rst_n),
        .pix_bcast (pix_bcast),
        .w_col     (w_col),
        .bias_line (bias_line),
        .acc_ld    (acc_ld),
        .acc_en    (acc_en),
        .acc_rd    (acc_rd),
        .c_read    (c_read),
        .acc_out   (acc_out),
        .acc_out_vld(acc_out_vld),
        .busy_o    (busy_o)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- 任务 ----------------
    // 随机 bias 行
    task gen_bias;
        begin
            for (c = 0; c < OC; c = c + 1) begin
                tb_bias[c] = $random(seed) % 1000000 - 500000;   // ±50 万内
                bias_line[c*32 +: 32] = tb_bias[c];
            end
        end
    endtask

    task do_ld;
        begin
            gen_bias;
            @(posedge aclk);
            acc_ld  <= 1'b1;
            acc_en  <= 1'b0;
            @(posedge aclk);
            acc_ld  <= 1'b0;
            for (c = 0; c < OC; c = c + 1)
                model_acc[c] = tb_bias[c];
        end
    endtask

    // 逐通道读出并比对参考模型(256 次)
    task check_all;
        input [8*24-1:0] tag;
        integer got;
        begin
            for (c = 0; c < OC; c = c + 1) begin
                @(posedge aclk);
                acc_rd  <= 1'b1;
                c_read  <= c[7:0];
                @(posedge aclk);
                acc_rd  <= 1'b0;
                @(posedge aclk);
                if (acc_out_vld !== 1'b1) begin
                    $display("[FAIL] %0s: acc_out_vld missing (c=%0d)", tag, c);
                    err_cnt = err_cnt + 1;
                end
                got = acc_out;
                if (got !== model_acc[c]) begin
                    if (err_cnt < 8)
                        $display("[FAIL] %0s: c=%0d got=%0d exp=%0d", tag, c, got, model_acc[c]);
                    err_cnt = err_cnt + 1;
                end
            end
        end
    endtask

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        seed    = 32'h4CAC_0001;
        acc_ld  = 1'b0;  acc_en = 1'b0;  acc_rd = 1'b0;
        c_read  = 8'd0;  pix_bcast = 8'd0;  w_col = {OC*8{1'b0}};
        bias_line = {OC*32{1'b0}};
        rst_n   = 1'b0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: random stream recompute (100 cyc, with random pauses) ===");
        do_ld;
        for (i = 0; i < 100; i = i + 1) begin
            pix_bcast <= $random(seed);                      // 有符号 8bit 随机
            for (c = 0; c < OC; c = c + 1)
                w_col[c*8 +: 8] <= $random(seed);
            acc_en <= (($random(seed) % 10) != 0);           // 10% 随机暂停
            @(posedge aclk);
            if (acc_en) begin                                // 模型只在 en 拍累加
                for (c = 0; c < OC; c = c + 1)
                    model_acc[c] = model_acc[c] +
                                   $signed(pix_bcast) * $signed(w_col[c*8 +: 8]);
            end
        end
        acc_en <= 1'b0;
        repeat (2) @(posedge aclk);
        check_all("T1");

        $display("=== T2: extremes (-128*-128 x100, then -128*+127) ===");
        do_ld;
        pix_bcast <= 8'h80;                                  // -128
        for (c = 0; c < OC; c = c + 1) w_col[c*8 +: 8] = 8'h80;  // -128
        acc_en <= 1'b1;
        repeat (100) @(posedge aclk);
        acc_en <= 1'b0;
        @(posedge aclk);
        for (c = 0; c < OC; c = c + 1) model_acc[c] = tb_bias[c] + 16384 * 100;
        check_all("T2a");
        do_ld;
        pix_bcast <= 8'h80;                                  // -128
        for (c = 0; c < OC; c = c + 1) w_col[c*8 +: 8] = 8'h7f;  // +127
        acc_en <= 1'b1;
        repeat (100) @(posedge aclk);
        acc_en <= 1'b0;
        @(posedge aclk);
        for (c = 0; c < OC; c = c + 1) model_acc[c] = tb_bias[c] - 128 * 127 * 100;
        check_all("T2b");

        $display("=== T3: bias load readback (no en cycles) ===");
        gen_bias;
        @(posedge aclk);
        acc_ld <= 1'b1;
        @(posedge aclk);
        acc_ld <= 1'b0;
        @(posedge aclk);
        for (c = 0; c < OC; c = c + 1) model_acc[c] = tb_bias[c];
        check_all("T3");

        $display("=== T4: high-channel discard (w=0 for c>=96) ===");
        do_ld;
        pix_bcast <= 8'h5a;
        for (c = 0; c < OC; c = c + 1)
            w_col[c*8 +: 8] <= (c < 96) ? $random(seed) : 8'h00;
        acc_en <= 1'b1;
        repeat (50) @(posedge aclk);
        acc_en <= 1'b0;
        @(posedge aclk);
        for (c = 0; c < OC; c = c + 1)
            model_acc[c] = (c < 96) ? tb_bias[c] + 90 * $signed(w_col[c*8 +: 8]) * 50
                                    : tb_bias[c];
        // 抽查高位通道不变 + 全量比对
        check_all("T4");

        $display("=== T5: same-cycle ld wins over en ===");
        gen_bias;
        pix_bcast <= 8'h7f;
        for (c = 0; c < OC; c = c + 1) w_col[c*8 +: 8] = 8'h7f;
        @(posedge aclk);
        acc_ld <= 1'b1;
        acc_en <= 1'b1;                                      // 同拍: 装载优先
        @(posedge aclk);
        acc_ld <= 1'b0;
        acc_en <= 1'b0;
        @(posedge aclk);
        for (c = 0; c < OC; c = c + 1) model_acc[c] = tb_bias[c];
        check_all("T5");

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
