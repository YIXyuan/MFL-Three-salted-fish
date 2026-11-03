`timescale 1ns / 1ps

module kosmo2_requant_v1_0 (
    input  wire               aclk,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [31:0] acc_in,
    input  wire signed [31:0] mc_in,
    input  wire [4:0]         fshift,
    input  wire               relu_en,
    output reg                q_valid,
    output reg  [7:0]         q_out
);

    reg signed [63:0] p_r;
    reg [4:0]         f_r;
    reg               relu_r;
    reg               s1_v;

    always @(posedge aclk) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
        end else begin
            s1_v   <= in_valid;
            p_r    <= acc_in * mc_in;
            f_r    <= fshift;
            relu_r <= relu_en;
        end
    end

    wire signed [63:0] rnd = (f_r == 5'd0) ? 64'sd0 : (64'sd1 <<< (f_r - 5'd1));
    wire signed [63:0] y   = (p_r + rnd) >>> f_r;
    wire signed [63:0] y_sat = (y > 64'sd127) ? 64'sd127 :
                               (y < -64'sd128) ? -64'sd128 : y;

    always @(posedge aclk) begin
        if (!rst_n) begin
            q_valid <= 1'b0;
            q_out   <= 8'd0;
        end else begin
            q_valid <= s1_v;
            if (relu_r && (y_sat < 0))
                q_out <= 8'd0;
            else
                q_out <= y_sat[7:0];
        end
    end

endmodule
