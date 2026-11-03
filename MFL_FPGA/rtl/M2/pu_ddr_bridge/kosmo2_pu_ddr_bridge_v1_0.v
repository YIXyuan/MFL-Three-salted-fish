`timescale 1ns / 1ps

module kosmo2_pu_ddr_bridge_v1_0 #(
    parameter integer C_DW        = 128,
    parameter integer C_IDW       = 4,
    parameter integer C_ASYNC     = 0,
    parameter integer C_AW_FIFO_D = 4,
    parameter integer C_W_FIFO_D  = 6,
    parameter integer C_B_FIFO_D  = 4,
    parameter integer C_AR_FIFO_D = 4,
    parameter integer C_R_FIFO_D  = 6
)(

    input  wire                    aclk_ui,
    input  wire                    rstn_ui,

    input  wire [C_IDW-1:0]        s_axi_awid,
    input  wire [31:0]             s_axi_awaddr,
    input  wire [7:0]              s_axi_awlen,
    input  wire                    s_axi_awvalid,
    output wire                    s_axi_awready,

    input  wire [C_DW-1:0]         s_axi_wdata,
    input  wire [C_DW/8-1:0]       s_axi_wstrb,
    input  wire                    s_axi_wlast,
    input  wire                    s_axi_wvalid,
    output wire                    s_axi_wready,

    output wire [C_IDW-1:0]        s_axi_bid,
    output wire [1:0]              s_axi_bresp,
    output wire                    s_axi_bvalid,
    input  wire                    s_axi_bready,

    input  wire [C_IDW-1:0]        s_axi_arid,
    input  wire [31:0]             s_axi_araddr,
    input  wire [7:0]              s_axi_arlen,
    input  wire                    s_axi_arvalid,
    output wire                    s_axi_arready,

    output wire [C_IDW-1:0]        s_axi_rid,
    output wire [C_DW-1:0]         s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output wire                    s_axi_rlast,
    output wire                    s_axi_rvalid,
    input  wire                    s_axi_rready,

    input  wire                    sps_clk_i,
    input  wire                    sps_resetn_i,

    output wire                    m_awvalid,
    input  wire                    m_awready,
    output wire [C_IDW-1:0]        m_awid,
    output wire [31:0]             m_awaddr,
    output wire [7:0]              m_awlen,
    output wire [2:0]              m_awsize,
    output wire [1:0]              m_awburst,
    output wire                    m_awlock,
    output wire [3:0]              m_awcache,
    output wire [2:0]              m_awprot,
    output wire [3:0]              m_awqos,

    output wire                    m_wvalid,
    input  wire                    m_wready,
    output wire [C_DW-1:0]         m_wdata,
    output wire [C_DW/8-1:0]       m_wstrb,
    output wire                    m_wlast,

    input  wire                    m_bvalid,
    output wire                    m_bready,
    input  wire [C_IDW-1:0]        m_bid,
    input  wire [1:0]              m_bresp,

    output wire                    m_arvalid,
    input  wire                    m_arready,
    output wire [C_IDW-1:0]        m_arid,
    output wire [31:0]             m_araddr,
    output wire [7:0]              m_arlen,
    output wire [2:0]              m_arsize,
    output wire [1:0]              m_arburst,
    output wire                    m_arlock,
    output wire [3:0]              m_arcache,
    output wire [2:0]              m_arprot,
    output wire [3:0]              m_arqos,

    input  wire                    m_rvalid,
    output wire                    m_rready,
    input  wire [C_IDW-1:0]        m_rid,
    input  wire [C_DW-1:0]         m_rdata,
    input  wire [1:0]              m_rresp,
    input  wire                    m_rlast
);

    localparam integer BYTES = C_DW / 8;

    function [2:0] size_of_beat;
        input integer bytes;
        begin
            if      (bytes ==  1) size_of_beat = 3'd0;
            else if (bytes ==  2) size_of_beat = 3'd1;
            else if (bytes ==  4) size_of_beat = 3'd2;
            else if (bytes ==  8) size_of_beat = 3'd3;
            else if (bytes == 16) size_of_beat = 3'd4;
            else if (bytes == 32) size_of_beat = 3'd5;
            else if (bytes == 64) size_of_beat = 3'd6;
            else                  size_of_beat = 3'd7;
        end
    endfunction

    localparam [2:0]  BEAT_SIZE = size_of_beat(BYTES);

    generate if (C_ASYNC == 0) begin : g_sync

        assign m_awvalid      = s_axi_awvalid;
        assign s_axi_awready  = m_awready;
        assign m_awid         = s_axi_awid;
        assign m_awaddr       = s_axi_awaddr;
        assign m_awlen        = s_axi_awlen;
        assign m_awsize       = BEAT_SIZE;
        assign m_awburst      = 2'b01;
        assign m_awlock       = 1'b0;
        assign m_awcache      = 4'b0011;
        assign m_awprot       = 3'b000;
        assign m_awqos        = 4'b0000;

        assign m_wvalid       = s_axi_wvalid;
        assign s_axi_wready   = m_wready;
        assign m_wdata        = s_axi_wdata;
        assign m_wstrb        = s_axi_wstrb;
        assign m_wlast        = s_axi_wlast;

        assign s_axi_bid      = m_bid;
        assign s_axi_bresp    = m_bresp;
        assign s_axi_bvalid   = m_bvalid;
        assign m_bready       = s_axi_bready;

        assign m_arvalid      = s_axi_arvalid;
        assign s_axi_arready  = m_arready;
        assign m_arid         = s_axi_arid;
        assign m_araddr       = s_axi_araddr;
        assign m_arlen        = s_axi_arlen;
        assign m_arsize       = BEAT_SIZE;
        assign m_arburst      = 2'b01;
        assign m_arlock       = 1'b0;
        assign m_arcache      = 4'b0011;
        assign m_arprot       = 3'b000;
        assign m_arqos        = 4'b0000;

        assign s_axi_rid      = m_rid;
        assign s_axi_rdata    = m_rdata;
        assign s_axi_rresp    = m_rresp;
        assign s_axi_rlast    = m_rlast;
        assign s_axi_rvalid   = m_rvalid;
        assign m_rready       = s_axi_rready;

    end else begin : g_async

        wire rstn_sps;
        kosmo2_rst_sync_v1_0 u_rst_sps (
            .clk       (sps_clk_i),
            .rst_n_in  (rstn_ui & sps_resetn_i),
            .rst_n_out (rstn_sps)
        );

        wire [C_IDW+32+8-1:0] aw_rdata;
        wire                  aw_rvalid, aw_rr;
        kosmo2_async_fifo_v1_0 #(.C_W(C_IDW+32+8), .C_D(C_AW_FIFO_D)) u_fifo_aw (
            .wclk(aclk_ui), .wrst_n(rstn_ui),
            .wdata({s_axi_awid, s_axi_awaddr, s_axi_awlen}),
            .wvalid(s_axi_awvalid),
            .wready(s_axi_awready),
            .wfull(),
            .rclk(sps_clk_i), .rrst_n(rstn_sps),
            .rdata(aw_rdata),
            .rvalid(aw_rvalid),
            .rready(aw_rr),
            .rempty()
        );
        assign {m_awid, m_awaddr, m_awlen} = aw_rdata;
        assign m_awvalid = aw_rvalid;
        assign aw_rr     = m_awready;
        assign m_awsize  = BEAT_SIZE;
        assign m_awburst = 2'b01;
        assign m_awlock  = 1'b0;
        assign m_awcache = 4'b0011;
        assign m_awprot  = 3'b000;
        assign m_awqos   = 4'b0000;

        wire [C_DW+C_DW/8+1-1:0] w_rdata;
        wire w_rvalid, w_rr;
        kosmo2_async_fifo_v1_0 #(.C_W(C_DW+C_DW/8+1), .C_D(C_W_FIFO_D)) u_fifo_w (
            .wclk(aclk_ui), .wrst_n(rstn_ui),
            .wdata({s_axi_wdata, s_axi_wstrb, s_axi_wlast}),
            .wvalid(s_axi_wvalid),
            .wready(s_axi_wready),
            .wfull(),
            .rclk(sps_clk_i), .rrst_n(rstn_sps),
            .rdata(w_rdata),
            .rvalid(w_rvalid),
            .rready(w_rr),
            .rempty()
        );
        assign {m_wdata, m_wstrb, m_wlast} = w_rdata;
        assign m_wvalid = w_rvalid;
        assign w_rr     = m_wready;

        wire [C_IDW+2-1:0] b_rdata;
        wire b_rvalid, b_rr;
        kosmo2_async_fifo_v1_0 #(.C_W(C_IDW+2), .C_D(C_B_FIFO_D)) u_fifo_b (
            .wclk(sps_clk_i), .wrst_n(rstn_sps),
            .wdata({m_bid, m_bresp}),
            .wvalid(m_bvalid),
            .wready(m_bready),
            .wfull(),
            .rclk(aclk_ui), .rrst_n(rstn_ui),
            .rdata(b_rdata),
            .rvalid(b_rvalid),
            .rready(s_axi_bready),
            .rempty()
        );
        assign {s_axi_bid, s_axi_bresp} = b_rdata;
        assign s_axi_bvalid = b_rvalid;

        wire [C_IDW+32+8-1:0] ar_rdata;
        wire ar_rvalid, ar_rr;
        kosmo2_async_fifo_v1_0 #(.C_W(C_IDW+32+8), .C_D(C_AR_FIFO_D)) u_fifo_ar (
            .wclk(aclk_ui), .wrst_n(rstn_ui),
            .wdata({s_axi_arid, s_axi_araddr, s_axi_arlen}),
            .wvalid(s_axi_arvalid),
            .wready(s_axi_arready),
            .wfull(),
            .rclk(sps_clk_i), .rrst_n(rstn_sps),
            .rdata(ar_rdata),
            .rvalid(ar_rvalid),
            .rready(ar_rr),
            .rempty()
        );
        assign {m_arid, m_araddr, m_arlen} = ar_rdata;
        assign m_arvalid = ar_rvalid;
        assign ar_rr     = m_arready;
        assign m_arsize  = BEAT_SIZE;
        assign m_arburst = 2'b01;
        assign m_arlock  = 1'b0;
        assign m_arcache = 4'b0011;
        assign m_arprot  = 3'b000;
        assign m_arqos   = 4'b0000;

        wire [C_IDW+C_DW+2+1-1:0] r_rdata;
        wire r_rvalid;
        kosmo2_async_fifo_v1_0 #(.C_W(C_IDW+C_DW+2+1), .C_D(C_R_FIFO_D)) u_fifo_r (
            .wclk(sps_clk_i), .wrst_n(rstn_sps),
            .wdata({m_rid, m_rdata, m_rresp, m_rlast}),
            .wvalid(m_rvalid),
            .wready(m_rready),
            .wfull(),
            .rclk(aclk_ui), .rrst_n(rstn_ui),
            .rdata(r_rdata),
            .rvalid(r_rvalid),
            .rready(s_axi_rready),
            .rempty()
        );
        assign {s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast} = r_rdata;
        assign s_axi_rvalid = r_rvalid;

    end endgenerate

endmodule
