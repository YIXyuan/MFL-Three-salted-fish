`timescale 1ns / 1ps

module kosmo2_wram_bank_v1_0 (
    input  wire             aclk,
    input  wire             rst_n,

    input  wire [3:0]       w_bank,
    input  wire [9:0]       w_col_idx,

    output wire [2047:0]    w_col,

    output wire [8191:0]    bias_line,
    output wire [8191:0]    mc_line
);

    wire [511:0]  cb0, cm0, cb1, cm1;
    wire [1023:0] cb2, cm2, cb3, cm3;
    wire [2047:0] cb4, cm4, cb5, cm5;
    wire [3071:0] cb6, cm6, cb7, cm7, cb8, cm8, cb9, cm9;

    kosmo2_wram_bank_const_v1_0 u_const (
        .bias0(cb0), .mc0(cm0),
        .bias1(cb1), .mc1(cm1),
        .bias2(cb2), .mc2(cm2),
        .bias3(cb3), .mc3(cm3),
        .bias4(cb4), .mc4(cm4),
        .bias5(cb5), .mc5(cm5),
        .bias6(cb6), .mc6(cm6),
        .bias7(cb7), .mc7(cm7),
        .bias8(cb8), .mc8(cm8),
        .bias9(cb9), .mc9(cm9)
    );

    wire [127:0] w0;
    wire [511:0] b0, m0;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(27), .C_OCH(16),
        .C_FILE_W("../../mem/conv00_w.mem")
    ) u_bank0 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb0), .mc_row(cm0),
        .w_q(w0), .bias_q(b0), .mc_q(m0)
    );

    wire [127:0] w1;
    wire [511:0] b1, m1;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(144), .C_OCH(16),
        .C_FILE_W("../../mem/conv01_w.mem")
    ) u_bank1 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb1), .mc_row(cm1),
        .w_q(w1), .bias_q(b1), .mc_q(m1)
    );

    wire [255:0] w2;
    wire [1023:0] b2, m2;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(144), .C_OCH(32),
        .C_FILE_W("../../mem/conv02_w.mem")
    ) u_bank2 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb2), .mc_row(cm2),
        .w_q(w2), .bias_q(b2), .mc_q(m2)
    );

    wire [255:0] w3;
    wire [1023:0] b3, m3;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(288), .C_OCH(32),
        .C_FILE_W("../../mem/conv03_w.mem")
    ) u_bank3 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb3), .mc_row(cm3),
        .w_q(w3), .bias_q(b3), .mc_q(m3)
    );

    wire [511:0] w4;
    wire [2047:0] b4, m4;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(288), .C_OCH(64),
        .C_FILE_W("../../mem/conv04_w.mem")
    ) u_bank4 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb4), .mc_row(cm4),
        .w_q(w4), .bias_q(b4), .mc_q(m4)
    );

    wire [511:0] w5;
    wire [2047:0] b5, m5;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(576), .C_OCH(64),
        .C_FILE_W("../../mem/conv05_w.mem")
    ) u_bank5 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb5), .mc_row(cm5),
        .w_q(w5), .bias_q(b5), .mc_q(m5)
    );

    wire [767:0] w6;
    wire [3071:0] b6, m6;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(576), .C_OCH(96),
        .C_FILE_W("../../mem/conv06_w.mem")
    ) u_bank6 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb6), .mc_row(cm6),
        .w_q(w6), .bias_q(b6), .mc_q(m6)
    );

    wire [767:0] w7;
    wire [3071:0] b7, m7;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(864), .C_OCH(96),
        .C_FILE_W("../../mem/conv07_w.mem")
    ) u_bank7 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb7), .mc_row(cm7),
        .w_q(w7), .bias_q(b7), .mc_q(m7)
    );

    wire [767:0] w8;
    wire [3071:0] b8, m8;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(864), .C_OCH(96),
        .C_FILE_W("../../mem/conv08_w.mem")
    ) u_bank8 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb8), .mc_row(cm8),
        .w_q(w8), .bias_q(b8), .mc_q(m8)
    );

    wire [767:0] w9;
    wire [3071:0] b9, m9;
    kosmo2_wram_bank_layer_v1_0 #(
        .C_DEPTH(864), .C_OCH(96),
        .C_FILE_W("../../mem/conv09_w.mem")
    ) u_bank9 (
        .aclk(aclk), .col_idx(w_col_idx),
        .bias_row(cb9), .mc_row(cm9),
        .w_q(w9), .bias_q(b9), .mc_q(m9)
    );

    wire [767:0]  wz0 = {{640{1'b0}}, w0};
    wire [767:0]  wz1 = {{640{1'b0}}, w1};
    wire [767:0]  wz2 = {{512{1'b0}}, w2};
    wire [767:0]  wz3 = {{512{1'b0}}, w3};
    wire [767:0]  wz4 = {{256{1'b0}}, w4};
    wire [767:0]  wz5 = {{256{1'b0}}, w5};
    wire [767:0]  wz6 = {{192{1'b0}}, w6};
    wire [767:0]  wz7 = w7;
    wire [767:0]  wz8 = w8;
    wire [767:0]  wz9 = w9;

    wire [3071:0] bz0 = {{2560{1'b0}}, b0};
    wire [3071:0] bz1 = {{2560{1'b0}}, b1};
    wire [3071:0] bz2 = {{2048{1'b0}}, b2};
    wire [3071:0] bz3 = {{2048{1'b0}}, b3};
    wire [3071:0] bz4 = {{1024{1'b0}}, b4};
    wire [3071:0] bz5 = {{1024{1'b0}}, b5};
    wire [3071:0] bz6 = b6;
    wire [3071:0] bz7 = b7;
    wire [3071:0] bz8 = b8;
    wire [3071:0] bz9 = b9;

    wire [3071:0] mz0 = {{2560{1'b0}}, m0};
    wire [3071:0] mz1 = {{2560{1'b0}}, m1};
    wire [3071:0] mz2 = {{2048{1'b0}}, m2};
    wire [3071:0] mz3 = {{2048{1'b0}}, m3};
    wire [3071:0] mz4 = {{1024{1'b0}}, m4};
    wire [3071:0] mz5 = {{1024{1'b0}}, m5};
    wire [3071:0] mz6 = m6;
    wire [3071:0] mz7 = m7;
    wire [3071:0] mz8 = m8;
    wire [3071:0] mz9 = m9;

    reg  [767:0]  w_mx;
    reg  [3071:0] b_mx, m_mx;
    always @(*) begin
        w_mx = 768'd0;
        b_mx = 3072'd0;
        m_mx = 3072'd0;
        case (w_bank)
            4'd0: begin w_mx = wz0; b_mx = bz0; m_mx = mz0; end
            4'd1: begin w_mx = wz1; b_mx = bz1; m_mx = mz1; end
            4'd2: begin w_mx = wz2; b_mx = bz2; m_mx = mz2; end
            4'd3: begin w_mx = wz3; b_mx = bz3; m_mx = mz3; end
            4'd4: begin w_mx = wz4; b_mx = bz4; m_mx = mz4; end
            4'd5: begin w_mx = wz5; b_mx = bz5; m_mx = mz5; end
            4'd6: begin w_mx = wz6; b_mx = bz6; m_mx = mz6; end
            4'd7: begin w_mx = wz7; b_mx = bz7; m_mx = mz7; end
            4'd8: begin w_mx = wz8; b_mx = bz8; m_mx = mz8; end
            4'd9: begin w_mx = wz9; b_mx = bz9; m_mx = mz9; end
            default: begin w_mx = 768'd0; b_mx = 3072'd0; m_mx = 3072'd0; end
        endcase
    end

    reg [767:0] w_d1;
    always @(posedge aclk) begin
        if (!rst_n) w_d1 <= 768'd0;
        else        w_d1 <= w_mx;
    end

    assign w_col     = {{1280{1'b0}}, w_d1};
    assign bias_line = {{5120{1'b0}}, b_mx};
    assign mc_line   = {{5120{1'b0}}, m_mx};

endmodule
