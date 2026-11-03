`timescale 1ns / 1ps

module kosmo2_wram_bank_layer_v1_0 #(
    parameter integer       C_DEPTH   = 27,
    parameter integer       C_OCH     = 16,
    parameter [8*40-1:0]    C_FILE_W  = "../../mem/conv00_w.mem"
)(
    input  wire                     aclk,
    input  wire [9:0]               col_idx,
    input  wire [C_OCH*32-1:0]      bias_row,
    input  wire [C_OCH*32-1:0]      mc_row,
    output reg  [C_OCH*8-1:0]       w_q,
    output wire [C_OCH*32-1:0]      bias_q,
    output wire [C_OCH*32-1:0]      mc_q
);

    reg [C_OCH*8-1:0] w_mem [0:C_DEPTH-1];

    initial begin
        $readmemh(C_FILE_W, w_mem);
    end

    always @(posedge aclk)
        w_q <= w_mem[col_idx];

    assign bias_q = bias_row;
    assign mc_q   = mc_row;

endmodule
