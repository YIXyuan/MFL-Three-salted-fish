`timescale 1ns / 1ps

module kosmo2_axi_dma_rd_v1_0 #(
    parameter integer C_DW        = 128,
    parameter integer C_MAX_BURST = 16
)(
    input  wire                    aclk,
    input  wire                    rst_n,

    input  wire [31:0]             cmd_base_addr,
    input  wire [23:0]             cmd_byte_len,
    input  wire                    cmd_valid,
    output reg                     cmd_ready,

    output reg  [C_DW-1:0]         m_data,
    output reg                     m_valid,
    output reg                     m_last,
    input  wire                    m_ready,

    output reg  [31:0]             m_axi_araddr,
    output reg  [7:0]              m_axi_arlen,
    output reg  [2:0]              m_axi_arsize,
    output reg                     m_axi_arvalid,
    input  wire                    m_axi_arready,
    output wire [1:0]              m_axi_arburst,
    output wire [2:0]              m_axi_arprot,

    input  wire [C_DW-1:0]         m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire                    m_axi_rvalid,
    output reg                     m_axi_rready,

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
    localparam [2:0]   ARSIZE_C = sz_of(BPB);
    localparam [31:0]  CMB_W    = C_MAX_BURST;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_AR     = 3'd1;
    localparam [2:0] ST_RBURST = 3'd2;
    localparam [2:0] ST_NEXT   = 3'd3;
    localparam [2:0] ST_DONE   = 3'd4;
    reg [2:0] state;

    reg [31:0] beat_rem;
    reg [7:0]  beat_idx;
    reg [7:0]  burst_beats_r;
    reg        burst_last_r;

    wire [31:0] ar_addr = (state == ST_IDLE) ? cmd_base_addr :
                          (state == ST_NEXT) ? (m_axi_araddr +
                                                ({24'd0, burst_beats_r} << LOG2_BPB)) :
                                               m_axi_araddr;
    wire [31:0] ar_rem  = (state == ST_IDLE) ? ({8'd0, cmd_byte_len} >> LOG2_BPB) :
                                               beat_rem;

    wire [12:0] bytes_to_4k = 13'h1000 - {1'b0, ar_addr[11:0]};
    wire [31:0] beats_4k    = {19'd0, bytes_to_4k} >> LOG2_BPB;
    wire [31:0] beats_cap   = (CMB_W < beats_4k) ? CMB_W : beats_4k;
    wire [31:0] ar_beats    = (beats_cap < ar_rem) ? beats_cap : ar_rem;

    wire r_hs = m_axi_rvalid && m_axi_rready;
    wire m_hs = m_valid && m_ready;
    wire last_beat_flag = burst_last_r && (beat_idx == m_axi_arlen);

    always @* begin
        m_axi_rready = (state == ST_RBURST) && (!m_valid || m_ready);
    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            m_data  <= {C_DW{1'b0}};
            m_valid <= 1'b0;
            m_last  <= 1'b0;
        end else if (r_hs) begin
            m_data  <= m_axi_rdata;
            m_valid <= 1'b1;
            m_last  <= last_beat_flag;
        end else if (m_hs) begin
            m_valid <= 1'b0;
            m_last  <= 1'b0;
        end

    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'h0;
            m_axi_arlen   <= 8'h0;
            m_axi_arsize  <= ARSIZE_C;
            beat_rem      <= 32'h0;
            beat_idx      <= 8'h0;
            burst_beats_r <= 8'h0;
            burst_last_r  <= 1'b0;
        end else begin
            case (state)

            ST_IDLE: begin
                if (cmd_valid) begin

                    m_axi_araddr  <= ar_addr;
                    m_axi_arlen   <= ar_beats[7:0] - 8'd1;
                    burst_beats_r <= ar_beats[7:0];
                    burst_last_r  <= (ar_beats == ar_rem);
                    beat_rem      <= ar_rem;
                    beat_idx      <= 8'd0;
                    m_axi_arvalid <= (ar_beats != 32'd0);
                    state         <= (ar_beats == 32'd0) ? ST_DONE : ST_AR;
                end
            end

            ST_AR: begin
                if (m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    state         <= ST_RBURST;
                end
            end

            ST_RBURST: begin
                if (r_hs) begin
                    if (m_axi_rlast) begin

                        beat_rem <= beat_rem - {24'd0, burst_beats_r};
                        beat_idx <= 8'd0;
                        state    <= burst_last_r ? ST_DONE : ST_NEXT;
                    end else begin
                        beat_idx <= beat_idx + 8'd1;
                    end
                end

            end

            ST_NEXT: begin
                m_axi_araddr  <= ar_addr;
                m_axi_arlen   <= ar_beats[7:0] - 8'd1;
                burst_beats_r <= ar_beats[7:0];
                burst_last_r  <= (ar_beats == ar_rem);
                m_axi_arvalid <= (ar_beats != 32'd0);
                state         <= (ar_beats == 32'd0) ? ST_DONE : ST_AR;
            end

            ST_DONE: begin
                if (!m_valid)
                    state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

    always @* begin
        cmd_ready = (state == ST_IDLE);
    end

    assign m_axi_arburst = 2'b01;
    assign m_axi_arprot  = 3'b000;
    assign busy_o = (state != ST_IDLE);

endmodule
