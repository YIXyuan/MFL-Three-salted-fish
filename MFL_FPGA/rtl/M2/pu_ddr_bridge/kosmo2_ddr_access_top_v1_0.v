`timescale 1ns / 1ps

module kosmo2_ddr_access_top_v1_0 #(
    parameter integer C_DW        = 128,
    parameter integer C_IDW       = 4,
    parameter integer C_ASYNC     = 0,
    parameter integer C_AW_FIFO_D = 4,
    parameter integer C_W_FIFO_D  = 6,
    parameter integer C_B_FIFO_D  = 4,
    parameter integer C_AR_FIFO_D = 4,
    parameter integer C_R_FIFO_D  = 6,
    parameter integer C_BIST_BURST_BEATS = 16,
    parameter integer C_BIST_TOTAL_BEATS = 4096
)(

    input  wire                 aclk_ui,
    input  wire                 rstn_ui,

    input  wire [C_IDW-1:0]     s_axi_awid,
    input  wire [31:0]          s_axi_awaddr,
    input  wire [7:0]           s_axi_awlen,
    input  wire                 s_axi_awvalid,
    output wire                 s_axi_awready,
    input  wire [C_DW-1:0]      s_axi_wdata,
    input  wire [C_DW/8-1:0]    s_axi_wstrb,
    input  wire                 s_axi_wlast,
    input  wire                 s_axi_wvalid,
    output wire                 s_axi_wready,
    output wire [C_IDW-1:0]     s_axi_bid,
    output wire [1:0]           s_axi_bresp,
    output wire                 s_axi_bvalid,
    input  wire                 s_axi_bready,
    input  wire [C_IDW-1:0]     s_axi_arid,
    input  wire [31:0]          s_axi_araddr,
    input  wire [7:0]           s_axi_arlen,
    input  wire                 s_axi_arvalid,
    output wire                 s_axi_arready,
    output wire [C_IDW-1:0]     s_axi_rid,
    output wire [C_DW-1:0]      s_axi_rdata,
    output wire [1:0]           s_axi_rresp,
    output wire                 s_axi_rlast,
    output wire                 s_axi_rvalid,
    input  wire                 s_axi_rready,

    input  wire                 sps_clk_i,
    input  wire                 sps_resetn_i,
    output wire                 m_awvalid,
    input  wire                 m_awready,
    output wire [C_IDW-1:0]     m_awid,
    output wire [31:0]          m_awaddr,
    output wire [7:0]           m_awlen,
    output wire [2:0]           m_awsize,
    output wire [1:0]           m_awburst,
    output wire                 m_awlock,
    output wire [3:0]           m_awcache,
    output wire [2:0]           m_awprot,
    output wire [3:0]           m_awqos,
    output wire                 m_wvalid,
    input  wire                 m_wready,
    output wire [C_DW-1:0]      m_wdata,
    output wire [C_DW/8-1:0]    m_wstrb,
    output wire                 m_wlast,
    input  wire                 m_bvalid,
    output wire                 m_bready,
    input  wire [C_IDW-1:0]     m_bid,
    input  wire [1:0]           m_bresp,
    output wire                 m_arvalid,
    input  wire                 m_arready,
    output wire [C_IDW-1:0]     m_arid,
    output wire [31:0]          m_araddr,
    output wire [7:0]           m_arlen,
    output wire [2:0]           m_arsize,
    output wire [1:0]           m_arburst,
    output wire                 m_arlock,
    output wire [3:0]           m_arcache,
    output wire [2:0]           m_arprot,
    output wire [3:0]           m_arqos,
    input  wire                 m_rvalid,
    output wire                 m_rready,
    input  wire [C_IDW-1:0]     m_rid,
    input  wire [C_DW-1:0]      m_rdata,
    input  wire [1:0]           m_rresp,
    input  wire                 m_rlast,

    input  wire                 bist_start,
    input  wire [31:0]          bist_base,
    input  wire [31:0]          bist_seed,
    output wire                 bist_busy,
    output wire                 bist_done,
    output wire                 bist_pass,
    output wire [15:0]          bist_err_cnt
);

    wire              arb_awvalid, arb_awready;
    wire [C_IDW-1:0]  arb_awid;
    wire [31:0]       arb_awaddr;
    wire [7:0]        arb_awlen;
    wire              arb_wvalid, arb_wready, arb_wlast;
    wire [C_DW-1:0]   arb_wdata;
    wire [C_DW/8-1:0] arb_wstrb;
    wire              arb_bvalid, arb_bready;
    wire [C_IDW-1:0]  arb_bid;
    wire [1:0]        arb_bresp;
    wire              arb_arvalid, arb_arready;
    wire [C_IDW-1:0]  arb_arid;
    wire [31:0]       arb_araddr;
    wire [7:0]        arb_arlen;
    wire              arb_rvalid, arb_rready, arb_rlast;
    wire [C_IDW-1:0]  arb_rid;
    wire [C_DW-1:0]   arb_rdata;
    wire [1:0]        arb_rresp;

    wire              bist_awvalid, bist_awready, bist_wvalid, bist_wready;
    wire              bist_wlast, bist_bvalid, bist_bready;
    wire              bist_arvalid, bist_arready, bist_rvalid, bist_rready, bist_rlast;
    wire [C_IDW-1:0]  bist_awid, bist_bid, bist_arid, bist_rid;
    wire [31:0]       bist_awaddr, bist_araddr;
    wire [7:0]        bist_awlen, bist_arlen;
    wire [C_DW-1:0]   bist_wdata, bist_rdata;
    wire [C_DW/8-1:0] bist_wstrb;
    wire [1:0]        bist_bresp, bist_rresp;

    kosmo2_ddr_bist_v1_0 #(
        .C_DW          (C_DW),
        .C_IDW         (C_IDW),
        .C_BURST_BEATS (C_BIST_BURST_BEATS),
        .C_TOTAL_BEATS (C_BIST_TOTAL_BEATS)
    ) u_bist (
        .aclk     (aclk_ui),
        .rstn     (rstn_ui),
        .start    (bist_start),
        .base     (bist_base),
        .seed     (bist_seed),
        .busy     (bist_busy),
        .done     (bist_done),
        .pass     (bist_pass),
        .err_cnt  (bist_err_cnt),
        .awvalid  (bist_awvalid),
        .awready  (bist_awready),
        .awid     (bist_awid),
        .awaddr   (bist_awaddr),
        .awlen    (bist_awlen),
        .wvalid   (bist_wvalid),
        .wready   (bist_wready),
        .wdata    (bist_wdata),
        .wstrb    (bist_wstrb),
        .wlast    (bist_wlast),
        .bvalid   (bist_bvalid),
        .bready   (bist_bready),
        .bresp    (bist_bresp),
        .arvalid  (bist_arvalid),
        .arready  (bist_arready),
        .arid     (bist_arid),
        .araddr   (bist_araddr),
        .arlen    (bist_arlen),
        .rvalid   (bist_rvalid),
        .rready   (bist_rready),
        .rdata    (bist_rdata),
        .rresp    (bist_rresp),
        .rlast    (bist_rlast)
    );

    kosmo2_axi_arb2_v1_0 #(
        .C_DW  (C_DW),
        .C_IDW (C_IDW)
    ) u_arb (
        .aclk      (aclk_ui),
        .rstn      (rstn_ui),

        .m0_awvalid(s_axi_awvalid), .m0_awready(s_axi_awready),
        .m0_awid   (s_axi_awid),    .m0_awaddr (s_axi_awaddr), .m0_awlen(s_axi_awlen),
        .m0_wvalid (s_axi_wvalid),  .m0_wready (s_axi_wready),
        .m0_wdata  (s_axi_wdata),   .m0_wstrb  (s_axi_wstrb),  .m0_wlast(s_axi_wlast),
        .m0_bvalid (s_axi_bvalid),  .m0_bready (s_axi_bready),
        .m0_bid    (s_axi_bid),     .m0_bresp  (s_axi_bresp),
        .m0_arvalid(s_axi_arvalid), .m0_arready(s_axi_arready),
        .m0_arid   (s_axi_arid),    .m0_araddr (s_axi_araddr), .m0_arlen(s_axi_arlen),
        .m0_rvalid (s_axi_rvalid),  .m0_rready (s_axi_rready),
        .m0_rid    (s_axi_rid),     .m0_rdata  (s_axi_rdata),
        .m0_rresp  (s_axi_rresp),   .m0_rlast  (s_axi_rlast),

        .m1_awvalid(bist_awvalid),  .m1_awready(bist_awready),
        .m1_awid   (bist_awid),     .m1_awaddr (bist_awaddr),  .m1_awlen(bist_awlen),
        .m1_wvalid (bist_wvalid),   .m1_wready (bist_wready),
        .m1_wdata  (bist_wdata),    .m1_wstrb  (bist_wstrb),   .m1_wlast(bist_wlast),
        .m1_bvalid (bist_bvalid),   .m1_bready (bist_bready),
        .m1_bid    (bist_bid),      .m1_bresp  (bist_bresp),
        .m1_arvalid(bist_arvalid),  .m1_arready(bist_arready),
        .m1_arid   (bist_arid),     .m1_araddr (bist_araddr),  .m1_arlen(bist_arlen),
        .m1_rvalid (bist_rvalid),   .m1_rready (bist_rready),
        .m1_rid    (bist_rid),      .m1_rdata  (bist_rdata),
        .m1_rresp  (bist_rresp),    .m1_rlast  (bist_rlast),

        .s_awvalid (arb_awvalid),   .s_awready (arb_awready),
        .s_awid    (arb_awid),      .s_awaddr  (arb_awaddr),   .s_awlen (arb_awlen),
        .s_wvalid  (arb_wvalid),    .s_wready  (arb_wready),
        .s_wdata   (arb_wdata),     .s_wstrb   (arb_wstrb),    .s_wlast (arb_wlast),
        .s_bvalid  (arb_bvalid),    .s_bready  (arb_bready),
        .s_bid     (arb_bid),       .s_bresp   (arb_bresp),
        .s_arvalid (arb_arvalid),   .s_arready (arb_arready),
        .s_arid    (arb_arid),      .s_araddr  (arb_araddr),   .s_arlen (arb_arlen),
        .s_rvalid  (arb_rvalid),    .s_rready  (arb_rready),
        .s_rid     (arb_rid),       .s_rdata   (arb_rdata),
        .s_rresp   (arb_rresp),     .s_rlast   (arb_rlast)
    );

    kosmo2_pu_ddr_bridge_v1_0 #(
        .C_DW        (C_DW),
        .C_IDW       (C_IDW),
        .C_ASYNC     (C_ASYNC),
        .C_AW_FIFO_D (C_AW_FIFO_D),
        .C_W_FIFO_D  (C_W_FIFO_D),
        .C_B_FIFO_D  (C_B_FIFO_D),
        .C_AR_FIFO_D (C_AR_FIFO_D),
        .C_R_FIFO_D  (C_R_FIFO_D)
    ) u_bridge (
        .aclk_ui      (aclk_ui),
        .rstn_ui      (rstn_ui),
        .s_axi_awid   (arb_awid),
        .s_axi_awaddr (arb_awaddr),
        .s_axi_awlen  (arb_awlen),
        .s_axi_awvalid(arb_awvalid),
        .s_axi_awready(arb_awready),
        .s_axi_wdata  (arb_wdata),
        .s_axi_wstrb  (arb_wstrb),
        .s_axi_wlast  (arb_wlast),
        .s_axi_wvalid (arb_wvalid),
        .s_axi_wready (arb_wready),
        .s_axi_bid    (arb_bid),
        .s_axi_bresp  (arb_bresp),
        .s_axi_bvalid (arb_bvalid),
        .s_axi_bready (arb_bready),
        .s_axi_arid   (arb_arid),
        .s_axi_araddr (arb_araddr),
        .s_axi_arlen  (arb_arlen),
        .s_axi_arvalid(arb_arvalid),
        .s_axi_arready(arb_arready),
        .s_axi_rid    (arb_rid),
        .s_axi_rdata  (arb_rdata),
        .s_axi_rresp  (arb_rresp),
        .s_axi_rlast  (arb_rlast),
        .s_axi_rvalid (arb_rvalid),
        .s_axi_rready (arb_rready),
        .sps_clk_i    (sps_clk_i),
        .sps_resetn_i (sps_resetn_i),
        .m_awvalid    (m_awvalid),
        .m_awready    (m_awready),
        .m_awid       (m_awid),
        .m_awaddr     (m_awaddr),
        .m_awlen      (m_awlen),
        .m_awsize     (m_awsize),
        .m_awburst    (m_awburst),
        .m_awlock     (m_awlock),
        .m_awcache    (m_awcache),
        .m_awprot     (m_awprot),
        .m_awqos      (m_awqos),
        .m_wvalid     (m_wvalid),
        .m_wready     (m_wready),
        .m_wdata      (m_wdata),
        .m_wstrb      (m_wstrb),
        .m_wlast      (m_wlast),
        .m_bvalid     (m_bvalid),
        .m_bready     (m_bready),
        .m_bid        (m_bid),
        .m_bresp      (m_bresp),
        .m_arvalid    (m_arvalid),
        .m_arready    (m_arready),
        .m_arid       (m_arid),
        .m_araddr     (m_araddr),
        .m_arlen      (m_arlen),
        .m_arsize     (m_arsize),
        .m_arburst    (m_arburst),
        .m_arlock     (m_arlock),
        .m_arcache    (m_arcache),
        .m_arprot     (m_arprot),
        .m_arqos      (m_arqos),
        .m_rvalid     (m_rvalid),
        .m_rready     (m_rready),
        .m_rid        (m_rid),
        .m_rdata      (m_rdata),
        .m_rresp      (m_rresp),
        .m_rlast      (m_rlast)
    );

endmodule
