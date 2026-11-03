`timescale 1ns / 1ps

module kosmo2_axi_dma_wr_v1_0 #(
    parameter integer C_DW        = 128,
    parameter integer C_MAX_BURST = 16
)(
    input  wire                    aclk,
    input  wire                    rst_n,

    input  wire [31:0]             cmd_base_addr,
    input  wire [23:0]             cmd_byte_len,
    input  wire                    cmd_valid,
    output reg                     cmd_ready,

    input  wire [C_DW-1:0]         s_data,
    input  wire                    s_valid,
    input  wire                    s_last,
    output reg                     s_ready,

    output reg  [31:0]             m_axi_awaddr,
    output reg  [7:0]              m_axi_awlen,
    output reg  [2:0]              m_axi_awsize,
    output reg  [1:0]              m_axi_awburst,
    output reg                     m_axi_awvalid,
    input  wire                    m_axi_awready,
    output wire [2:0]              m_axi_awprot,

    output reg  [C_DW-1:0]         m_axi_wdata,
    output reg  [C_DW/8-1:0]       m_axi_wstrb,
    output reg                     m_axi_wlast,
    output reg                     m_axi_wvalid,
    input  wire                    m_axi_wready,

    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output reg                     m_axi_bready,

    output wire                    busy_o
);

    localparam integer BPB      = C_DW / 8;
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction
    function [2:0] sz_of;
        input integer bytes;
        begin
            case (bytes)
                1:  sz_of = 3'd0;
                2:  sz_of = 3'd1;
                4:  sz_of = 3'd2;
                8:  sz_of = 3'd3;
                default: sz_of = 3'd4;
            endcase
        end
    endfunction
    localparam integer LOG2_BPB = clog2(BPB);
    localparam [2:0]   AWSIZE_C = sz_of(BPB);
    localparam [31:0]  CMB_W    = C_MAX_BURST;

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_AW   = 3'd1;
    localparam [2:0] ST_W    = 3'd2;
    localparam [2:0] ST_B    = 3'd3;
    localparam [2:0] ST_NEXT = 3'd4;
    localparam [2:0] ST_DONE = 3'd5;
    reg [2:0] state;

    reg [31:0] beat_rem;
    reg [23:0] total_beats;
    reg [23:0] captured_cnt;
    reg [7:0]  beat_idx;
    reg [7:0]  burst_beats_r;
    reg        burst_last_r;

    reg        w_valid_r;
    reg [C_DW-1:0] wdata_r;

    wire [31:0] aw_addr = (state == ST_IDLE) ? cmd_base_addr :
                          (state == ST_NEXT) ? (m_axi_awaddr +
                                                ({24'd0, burst_beats_r} << LOG2_BPB)) :
                                               m_axi_awaddr;
    wire [31:0] aw_rem  = (state == ST_IDLE) ? ({8'd0, cmd_byte_len} >> LOG2_BPB) :
                                               beat_rem;

    wire [12:0] bytes_to_4k = 13'h1000 - {1'b0, aw_addr[11:0]};
    wire [31:0] beats_4k    = {19'd0, bytes_to_4k} >> LOG2_BPB;
    wire [31:0] beats_cap   = (CMB_W < beats_4k) ? CMB_W : beats_4k;
    wire [31:0] aw_beats    = (beats_cap < aw_rem) ? beats_cap : aw_rem;

    wire w_hs = m_axi_wvalid && m_axi_wready;
    wire slot_free   = !w_valid_r || (m_axi_wready && (beat_idx != m_axi_awlen));

    wire can_capture = (state == ST_W) && s_valid &&
                       (captured_cnt < total_beats) && slot_free;

    always @* begin
        cmd_ready     = (state == ST_IDLE);
        s_ready       = can_capture;
        m_axi_wdata   = wdata_r;
        m_axi_wstrb   = {C_DW/8{1'b1}};
        m_axi_wvalid  = w_valid_r && (state == ST_W);
        m_axi_wlast   = m_axi_wvalid && (beat_idx == m_axi_awlen);
        m_axi_awsize  = AWSIZE_C;
        m_axi_awburst = 2'b01;
        m_axi_bready  = (state == ST_B);
    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            w_valid_r    <= 1'b0;
            wdata_r      <= {C_DW{1'b0}};
        end else if (can_capture) begin
            wdata_r      <= s_data;
            w_valid_r    <= 1'b1;
        end else if (w_hs) begin
            w_valid_r    <= 1'b0;
        end

    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            m_axi_awvalid <= 1'b0;
            m_axi_awaddr  <= 32'h0;
            m_axi_awlen   <= 8'h0;
            beat_rem      <= 32'h0;
            total_beats   <= 24'd0;
            captured_cnt  <= 24'd0;
            beat_idx      <= 8'h0;
            burst_beats_r <= 8'h0;
            burst_last_r  <= 1'b0;
        end else begin
            case (state)

            ST_IDLE: begin
                if (cmd_valid) begin

                    m_axi_awaddr  <= aw_addr;
                    m_axi_awlen   <= aw_beats[7:0] - 8'd1;
                    burst_beats_r <= aw_beats[7:0];
                    burst_last_r  <= (aw_beats == aw_rem);
                    beat_rem      <= aw_rem;
                    total_beats   <= aw_rem[23:0];
                    captured_cnt  <= 24'd0;
                    beat_idx      <= 8'd0;
                    m_axi_awvalid <= (aw_beats != 32'd0);
                    state         <= (aw_beats == 32'd0) ? ST_DONE : ST_AW;
                end
            end

            ST_AW: begin
                if (m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    state         <= ST_W;
                end
            end

            ST_W: begin
                if (can_capture)
                    captured_cnt <= captured_cnt + 24'd1;
                if (w_hs) begin
                    beat_rem <= beat_rem - 32'd1;
                    if (beat_idx == m_axi_awlen) begin
                        beat_idx <= 8'd0;
                        state    <= ST_B;
                    end else begin
                        beat_idx <= beat_idx + 8'd1;
                    end
                end

            end

            ST_B: begin
                if (m_axi_bvalid) begin
                    state <= burst_last_r ? ST_DONE : ST_NEXT;
                end
            end

            ST_NEXT: begin
                m_axi_awaddr  <= aw_addr;
                m_axi_awlen   <= aw_beats[7:0] - 8'd1;
                burst_beats_r <= aw_beats[7:0];
                burst_last_r  <= (aw_beats == aw_rem);
                m_axi_awvalid <= (aw_beats != 32'd0);
                state         <= (aw_beats == 32'd0) ? ST_DONE : ST_AW;
            end

            ST_DONE: begin
                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

    assign m_axi_awprot = 3'b000;
    assign busy_o = (state != ST_IDLE);

endmodule
