`timescale 1ns / 1ps

module kosmo2_ddr_flag_writer_v1_0 #(
    parameter integer C_DW  = 128,
    parameter integer C_IDW = 4
)(
    input  wire             aclk,
    input  wire             rstn,
    input  wire             start,
    input  wire [31:0]      addr,
    input  wire [C_DW-1:0]  wdata,
    output wire             busy,
    output reg              done,

    output wire             awvalid,
    input  wire             awready,
    output wire [C_IDW-1:0] awid,
    output wire [31:0]      awaddr,
    output wire [7:0]       awlen,
    output wire [2:0]       awsize,
    output wire [1:0]       awburst,
    output wire             wvalid,
    input  wire             wready,
    output wire [C_DW-1:0]  wdata_o,
    output wire [C_DW/8-1:0] wstrb,
    output wire             wlast,
    input  wire             bvalid,
    output wire             bready,
    input  wire [C_IDW-1:0] bid,
    input  wire [1:0]       bresp,
    output wire             arvalid,
    input  wire             arready,
    input  wire             rvalid,
    output wire             rready
);

    localparam [1:0] S_IDLE = 2'd0, S_AW = 2'd1, S_B = 2'd2;
    localparam integer BYTES = C_DW / 8;

    function [2:0] beat_size;
        input integer bytes;
        begin
            if      (bytes ==  1) beat_size = 3'd0;
            else if (bytes ==  2) beat_size = 3'd1;
            else if (bytes ==  4) beat_size = 3'd2;
            else if (bytes ==  8) beat_size = 3'd3;
            else if (bytes == 16) beat_size = 3'd4;
            else if (bytes == 32) beat_size = 3'd5;
            else if (bytes == 64) beat_size = 3'd6;
            else                  beat_size = 3'd7;
        end
    endfunction

    reg [1:0] state;
    reg [31:0] addr_r;
    reg [C_DW-1:0] wdata_r;
    reg aw_ok, w_ok;

    assign busy    = (state != S_IDLE);
    assign awid    = {C_IDW{1'b0}};
    assign awaddr  = addr_r;
    assign awlen   = 8'd0;
    assign awsize  = beat_size(BYTES);
    assign awburst = 2'b01;
    assign awvalid = (state == S_AW) & !aw_ok;
    assign wvalid  = (state == S_AW) & !w_ok;
    assign wdata_o = wdata_r;
    assign wstrb   = {(BYTES){1'b1}};
    assign wlast   = 1'b1;
    assign bready  = 1'b1;
    assign arvalid = 1'b0;
    assign rready  = 1'b1;

    always @(posedge aclk or negedge rstn) begin
        if (!rstn) begin
            state   <= S_IDLE;
            done    <= 1'b0;
            addr_r  <= 32'd0;
            wdata_r <= {C_DW{1'b0}};
            aw_ok   <= 1'b0;
            w_ok    <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        addr_r  <= addr;
                        wdata_r <= wdata;
                        aw_ok   <= 1'b0;
                        w_ok    <= 1'b0;
                        state   <= S_AW;
                    end
                end
                S_AW: begin
                    if (awvalid & awready)
                        aw_ok <= 1'b1;
                    if (wvalid & wready)
                        w_ok <= 1'b1;
                    if (((aw_ok | (awvalid & awready)) & (w_ok | (wvalid & wready))))
                        state <= S_B;
                end
                S_B: begin
                    if (bvalid) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
