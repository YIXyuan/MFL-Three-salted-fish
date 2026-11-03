`timescale 1ns / 1ps

module kosmo2_frame_reader_v1_0 #(
    parameter integer C_DW  = 128,
    parameter integer C_IDW = 4
)(
    input  wire             aclk,
    input  wire             rstn,

    input  wire             start,
    input  wire [31:0]      cfg_base,
    input  wire [31:0]      cfg_stride,
    input  wire [15:0]      cfg_width,
    input  wire [15:0]      cfg_height,
    input  wire [2:0]       cfg_pixel_b,

    output wire             busy,
    output reg              done,

    output wire [C_DW-1:0]  px_tdata,
    output wire             px_tvalid,
    input  wire             px_tready,
    output wire             px_sop,
    output wire             px_eol,
    output wire             px_tlast,

    output wire             awvalid,
    input  wire             awready,
    output wire [C_IDW-1:0] awid,
    output wire [31:0]      awaddr,
    output wire [7:0]       awlen,
    output wire             wvalid,
    input  wire             wready,
    output wire [C_DW-1:0]  wdata,
    output wire [C_DW/8-1:0] wstrb,
    output wire             wlast,
    input  wire             bvalid,
    output wire             bready,
    input  wire [C_IDW-1:0] bid,
    input  wire [1:0]       bresp,
    output reg              arvalid,
    input  wire             arready,
    output wire [C_IDW-1:0] arid,
    output reg  [31:0]      araddr,
    output reg  [7:0]       arlen,
    input  wire             rvalid,
    output wire             rready,
    input  wire [C_IDW-1:0] rid,
    input  wire [C_DW-1:0]  rdata,
    input  wire [1:0]       rresp,
    input  wire             rlast
);

    localparam [1:0] S_IDLE     = 2'd0,
                     S_ROW_ADDR = 2'd1,
                     S_RD_DATA  = 2'd2,
                     S_DONE     = 2'd3;

    localparam integer BYTES = C_DW / 8;
    localparam integer MAX_BURST = 256;

    reg [31:0] base_r, stride_r;
    reg [15:0] width_r, height_r;
    reg [2:0]  pixel_b_r;
    wire [23:0] row_bytes_cfg = width_r * pixel_b_r;
    wire [23:0] row_beats_cfg = (row_bytes_cfg + BYTES - 1) / BYTES;

    reg [1:0]   state;
    reg [15:0]  row_cnt;
    reg [23:0]  row_rem_b;
    reg [23:0]  burst_rem;
    reg [31:0]  burst_addr;
    reg         row_first;
    reg         first_beat;
    wire [23:0] burst_beats_nxt = row_first ? row_beats_cfg
                                            : ((burst_rem > MAX_BURST) ? MAX_BURST : burst_rem);

    assign busy   = (state != S_IDLE);
    assign rready = (state == S_RD_DATA) & px_tready;

    assign px_tdata  = rdata;
    assign px_tvalid = (state == S_RD_DATA) & rvalid;
    assign px_sop    = px_tvalid & first_beat;
    assign px_eol    = px_tvalid & (row_rem_b <= BYTES);
    assign px_tlast  = px_eol & (row_cnt == height_r - 1);

    assign awvalid = 1'b0;
    assign awid    = {C_IDW{1'b0}};
    assign awaddr  = 32'd0;
    assign awlen   = 8'd0;
    assign wvalid  = 1'b0;
    assign wdata   = {C_DW{1'b0}};
    assign wstrb   = {(BYTES){1'b0}};
    assign wlast   = 1'b0;
    assign bready  = 1'b1;
    assign arid    = {C_IDW{1'b0}};

    always @(posedge aclk or negedge rstn) begin
        if (!rstn) begin
            state      <= S_IDLE;
            row_cnt    <= 16'd0;
            burst_rem  <= 24'd0;
            burst_addr <= 32'd0;
            row_first  <= 1'b0;
            first_beat <= 1'b0;
            done       <= 1'b0;
            arvalid    <= 1'b0;
            araddr     <= 32'd0;
            arlen      <= 8'd0;
            base_r     <= 32'd0;
            stride_r   <= 32'd0;
            width_r    <= 16'd0;
            height_r   <= 16'd0;
            pixel_b_r  <= 3'd2;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        base_r    <= cfg_base;
                        stride_r  <= cfg_stride;
                        width_r   <= cfg_width;
                        height_r  <= cfg_height;
                        pixel_b_r <= (cfg_pixel_b == 3'd1 || cfg_pixel_b == 3'd2 ||
                                      cfg_pixel_b == 3'd4) ? cfg_pixel_b : 3'd2;
                        row_cnt    <= 16'd0;
                        row_first  <= 1'b1;
                        first_beat <= 1'b1;

                        if (cfg_width == 16'd0 || cfg_height == 16'd0)
                            state <= S_DONE;
                        else
                            state <= S_ROW_ADDR;
                    end
                end

                S_ROW_ADDR: begin
                    arvalid <= 1'b1;
                    araddr  <= row_first ? (base_r + row_cnt * stride_r) : burst_addr;
                    arlen   <= (burst_beats_nxt >= MAX_BURST) ? 8'd255
                             : (burst_beats_nxt[7:0] - 8'd1);
                    if (row_first) begin
                        burst_rem <= row_beats_cfg;
                        row_rem_b <= row_bytes_cfg;
                    end
                    if (arvalid & arready) begin
                        arvalid <= 1'b0;
                        state   <= S_RD_DATA;
                    end
                end

                S_RD_DATA: begin
                    if (rvalid & rready) begin
                        if (first_beat)
                            first_beat <= 1'b0;

                        if (row_rem_b > BYTES)
                            row_rem_b <= row_rem_b - BYTES;
                        else
                            row_rem_b <= 24'd0;

                        if (rlast) begin
                            if (burst_rem > (arlen + 9'd1)) begin

                                burst_rem  <= burst_rem - (arlen + 9'd1);
                                burst_addr <= araddr + ((arlen + 9'd1) * BYTES);
                                state      <= S_ROW_ADDR;
                            end else if (row_cnt == height_r - 1) begin
                                state <= S_DONE;
                            end else begin
                                row_cnt   <= row_cnt + 16'd1;
                                row_first <= 1'b1;
                                state     <= S_ROW_ADDR;
                            end
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    always @(posedge aclk) begin
        if (state == S_RD_DATA && rvalid && rresp != 2'b00)
            $display("[%t] FRAME_READER: rresp error at row=%0d", $time, row_cnt);
    end

endmodule
