`timescale 1ns / 1ps

module kosmo2_mac_array_v1_0 #(
    parameter integer C_OC = 256
)(
    input  wire                      aclk,
    input  wire                      rst_n,
    input  wire [7:0]                pix_bcast,
    input  wire [C_OC*8-1:0]         w_col,
    input  wire [C_OC*32-1:0]        bias_line,
    input  wire                      acc_ld,
    input  wire                      acc_en,
    input  wire                      acc_rd,
    input  wire [$clog2(C_OC)-1:0]   c_read,
    output reg  signed [31:0]        acc_out,
    output reg                       acc_out_vld,
    output wire                      busy_o
);

    reg signed [31:0] acc [0:C_OC-1];

    genvar c;
    generate
        for (c = 0; c < C_OC; c = c + 1) begin : G_APM
            wire signed [15:0] prod = $signed(pix_bcast) * $signed(w_col[c*8 +: 8]);
            always @(posedge aclk) begin
                if (acc_ld)
                    acc[c] <= $signed(bias_line[c*32 +: 32]);
                else if (acc_en)
                    acc[c] <= acc[c] + prod;
            end
        end
    endgenerate

    always @(posedge aclk) begin
        if (!rst_n) begin
            acc_out     <= 32'd0;
            acc_out_vld <= 1'b0;
        end else begin
            acc_out_vld <= acc_rd;
            if (acc_rd)
                acc_out <= acc[c_read];
        end
    end

    assign busy_o = acc_ld | acc_en | acc_rd;

endmodule
