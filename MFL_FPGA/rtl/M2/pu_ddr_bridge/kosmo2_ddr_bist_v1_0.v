`timescale 1ns / 1ps

module kosmo2_ddr_bist_v1_0 #(
    parameter integer C_DW          = 128,
    parameter integer C_IDW         = 4,
    parameter integer C_BURST_BEATS = 16,
    parameter integer C_TOTAL_BEATS = 4096
)(
    input  wire             aclk,
    input  wire             rstn,

    input  wire             start,
    input  wire [31:0]      base,
    input  wire [31:0]      seed,
    output wire             busy,
    output wire             done,
    output wire             pass,
    output wire [15:0]      err_cnt,

    output reg              awvalid,
    input  wire             awready,
    output wire [C_IDW-1:0] awid,
    output reg  [31:0]      awaddr,
    output wire [7:0]       awlen,
    output wire             wvalid,
    input  wire             wready,
    output wire [C_DW-1:0]  wdata,
    output wire [C_DW/8-1:0] wstrb,
    output wire             wlast,
    input  wire             bvalid,
    output wire             bready,
    input  wire [1:0]       bresp,
    output reg              arvalid,
    input  wire             arready,
    output wire [C_IDW-1:0] arid,
    output reg  [31:0]      araddr,
    output wire [7:0]       arlen,
    input  wire             rvalid,
    output wire             rready,
    input  wire [C_DW-1:0]  rdata,
    input  wire [1:0]       rresp,
    input  wire             rlast
);

    localparam [2:0] S_IDLE     = 3'd0,
                     S_WR_ADDR  = 3'd1,
                     S_WR_DATA  = 3'd2,
                     S_WR_B     = 3'd3,
                     S_RD_ADDR  = 3'd4,
                     S_RD_DATA  = 3'd5,
                     S_DONE     = 3'd6;

    localparam integer BYTES = C_DW / 8;

    reg  [2:0]  state;
    reg  [23:0] beat_cnt;
    reg  [7:0]  sub_beat;
    reg  [31:0] base_r, seed_r;
    reg         done_r, pass_r;
    reg  [15:0] err_r;

    assign busy    = (state != S_IDLE) && (state != S_DONE);
    assign done    = done_r;
    assign pass    = pass_r;
    assign err_cnt = err_r;

    function [127:0] pat128;
        input [31:0] idx;
        input [31:0] seed;
        begin
            pat128 = {seed ^ idx, seed + idx, seed - idx, seed ^ ~idx};
        end
    endfunction

    wire [127:0]    expect128   = pat128(beat_cnt + sub_beat, seed_r);
    wire [C_DW-1:0] expect_data = expect128[C_DW-1:0];

    assign awid   = {C_IDW{1'b0}};
    assign awlen  = C_BURST_BEATS - 1;
    assign wvalid = (state == S_WR_DATA);
    assign wdata  = pat128(beat_cnt + sub_beat, seed_r);
    assign wlast  = (sub_beat == C_BURST_BEATS - 1);
    assign wstrb  = {(BYTES){1'b1}};
    assign bready = 1'b1;

    assign arid   = {C_IDW{1'b0}};
    assign arlen  = C_BURST_BEATS - 1;
    assign rready = (state == S_RD_DATA);

    always @(posedge aclk or negedge rstn) begin
        if (!rstn) begin
            state   <= S_IDLE;
            beat_cnt<= 24'd0;
            sub_beat<= 8'd0;
            base_r  <= 32'd0;
            seed_r  <= 32'h5eed_0000;
            done_r  <= 1'b0;
            pass_r  <= 1'b0;
            err_r   <= 16'd0;
            awvalid <= 1'b0;
            awaddr  <= 32'd0;
            arvalid <= 1'b0;
            araddr  <= 32'd0;
        end else begin
            done_r <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        base_r   <= base;
                        seed_r   <= seed;
                        beat_cnt <= 24'd0;
                        sub_beat <= 8'd0;
                        err_r    <= 16'd0;
                        pass_r   <= 1'b0;
                        state    <= S_WR_ADDR;
                    end
                end

                S_WR_ADDR: begin
                    awvalid <= 1'b1;
                    awaddr  <= base_r + (beat_cnt * BYTES);
                    if (awvalid & awready) begin
                        awvalid <= 1'b0;
                        state   <= S_WR_DATA;
                    end
                end
                S_WR_DATA: begin
                    if (wvalid & wready) begin
                        if (wlast)
                            state <= S_WR_B;
                        sub_beat <= sub_beat + 8'd1;
                    end
                end
                S_WR_B: begin
                    if (bvalid) begin

                        beat_cnt <= (beat_cnt + C_BURST_BEATS >= C_TOTAL_BEATS)
                                    ? 24'd0 : (beat_cnt + C_BURST_BEATS);
                        sub_beat <= 8'd0;
                        state    <= (beat_cnt + C_BURST_BEATS >= C_TOTAL_BEATS)
                                    ? S_RD_ADDR : S_WR_ADDR;
                    end
                end

                S_RD_ADDR: begin
                    arvalid <= 1'b1;
                    araddr  <= base_r + (beat_cnt * BYTES);
                    if (arvalid & arready) begin
                        arvalid <= 1'b0;
                        state   <= S_RD_DATA;
                    end
                end
                S_RD_DATA: begin
                    if (rvalid) begin

                        if ((rdata !== expect_data) || (rresp != 2'b00)) begin
                            if (err_r < 16'hFFFF)
                                err_r <= err_r + 16'd1;
                        end
                        if (rlast) begin
                            beat_cnt <= beat_cnt + C_BURST_BEATS;
                            sub_beat <= 8'd0;
                            state    <= (beat_cnt + C_BURST_BEATS >= C_TOTAL_BEATS)
                                        ? S_DONE : S_RD_ADDR;
                        end else begin
                            sub_beat <= sub_beat + 8'd1;
                        end
                    end
                end

                S_DONE: begin
                    done_r <= 1'b1;
                    pass_r <= (err_r == 16'd0);
                    state  <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    always @(posedge aclk) begin
        if (state == S_RD_DATA && rvalid &&
            (rdata !== expect_data))
            $display("[%t] BIST MISMATCH beat=%0d addr=0x%08h got=%h exp=%h",
                     $time, beat_cnt + sub_beat, base_r + (beat_cnt + sub_beat)*BYTES,
                     rdata, expect_data);
    end

endmodule
