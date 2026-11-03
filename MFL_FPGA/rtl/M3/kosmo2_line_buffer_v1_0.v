`timescale 1ns / 1ps

module kosmo2_line_buffer_v1_0 #(
    parameter integer C_ROW_BYTES = 16384,
    parameter integer C_CH_BITS   = 7,
    parameter integer C_X_BITS    = 11
)(
    input  wire                    aclk,
    input  wire                    rst_n,

    input  wire [C_X_BITS-1:0]     cfg_w,
    input  wire [C_CH_BITS-1:0]    cfg_c,
    input  wire                    cfg_load,

    input  wire                    ld_start,
    input  wire [1:0]              ld_bank,
    input  wire [C_CH_BITS-1:0]    ld_ch,
    input  wire                    ld_valid,
    output wire                    ld_ready,
    input  wire [7:0]              ld_data,
    output reg                     ld_done,

    input  wire                    rd_valid,
    input  wire [1:0]              rd_bank0,
    input  wire [2:0]              rd_row_ok,
    input  wire [1:0]              rd_ky,
    input  wire [1:0]              rd_kw,
    input  wire [C_CH_BITS-1:0]    rd_cin,
    input  wire [C_X_BITS-1:0]     rd_x,
    output reg  [7:0]              rd_data,
    output reg                     rd_data_vld,

    output wire [1:0]              dbg_bank
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction
    localparam integer AW = clog2(C_ROW_BYTES);

    reg [7:0] bank0 [0:C_ROW_BYTES-1];
    reg [7:0] bank1 [0:C_ROW_BYTES-1];
    reg [7:0] bank2 [0:C_ROW_BYTES-1];

    reg                ld_active;
    reg [C_X_BITS-1:0] x_cnt;
    reg [1:0]          ld_bank_r;
    wire               ld_fire = ld_active & ld_valid;

    wire [AW-1:0]      ld_addr = (x_cnt * cfg_c) + ld_ch;

    assign ld_ready = ld_active;
    assign dbg_bank = ld_bank_r;

    always @(posedge aclk) begin
        if (!rst_n) begin
            ld_active <= 1'b0;
            x_cnt     <= {C_X_BITS{1'b0}};
            ld_done   <= 1'b0;
            ld_bank_r <= 2'd0;
        end else begin
            ld_done <= 1'b0;
            if (cfg_load)
                x_cnt <= {C_X_BITS{1'b0}};
            if (ld_start && !ld_active) begin
                ld_active <= 1'b1;
                x_cnt     <= {C_X_BITS{1'b0}};
                ld_bank_r <= ld_bank;
            end else if (ld_fire) begin
                case (ld_bank_r)
                2'd0:    bank0[ld_addr] <= ld_data;
                2'd1:    bank1[ld_addr] <= ld_data;
                default: bank2[ld_addr] <= ld_data;
                endcase
                if (x_cnt == cfg_w - 1'b1) begin
                    ld_active <= 1'b0;
                    ld_done   <= 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    wire [2:0] bsum    = rd_bank0 + rd_ky;
    wire [1:0] rd_bank = (bsum == 3'd3) ? 2'd0 :
                         (bsum == 3'd4) ? 2'd1 : bsum[1:0];
    wire       col_pad = (rd_kw == 2'd0 && rd_x == {C_X_BITS{1'b0}}) ||
                         (rd_kw == 2'd2 && rd_x >= cfg_w - 1'b1);
    wire [C_X_BITS-1:0] x1 = (rd_kw == 2'd2) ? (rd_x + 1'b1) :
                             (rd_kw == 2'd0) ? (rd_x - 1'b1) : rd_x;
    wire       row_pad = !rd_row_ok[rd_ky];
    wire [AW-1:0] rd_addr = col_pad ? {AW{1'b0}} : (x1 * cfg_c) + rd_cin;

    reg [AW-1:0] s1_addr;
    reg          s1_pad;
    reg [1:0]    s1_bank;
    reg          s1_v;

    always @(posedge aclk) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
        end else begin
            s1_v    <= rd_valid;
            s1_addr <= rd_addr;
            s1_pad  <= row_pad || col_pad;
            s1_bank <= rd_bank;
        end
    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            rd_data     <= 8'd0;
            rd_data_vld <= 1'b0;
        end else begin
            rd_data_vld <= s1_v;
            if (s1_pad)
                rd_data <= 8'd0;
            else begin
                case (s1_bank)
                2'd0:    rd_data <= bank0[s1_addr];
                2'd1:    rd_data <= bank1[s1_addr];
                default: rd_data <= bank2[s1_addr];
                endcase
            end
        end
    end

endmodule
