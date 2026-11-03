`timescale 1ns / 1ps

module kosmo2_rst_sync_v1_0 (
    input  wire clk,
    input  wire rst_n_in,
    output wire rst_n_out
);

    reg [1:0] sync_ff;

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)
            sync_ff <= 2'b00;
        else
            sync_ff <= {sync_ff[0], 1'b1};
    end

    assign rst_n_out = sync_ff[1];

endmodule
