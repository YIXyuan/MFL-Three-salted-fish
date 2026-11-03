`timescale 1ns / 1ps

module kosmo2_m9_top_v1_0 #(
    parameter [31:0] C_BIST_BASE  = 32'h00C8_0000,
    parameter [31:0] C_BIST_SEED  = 32'hbeef_1234,
    parameter [31:0] C_REBUF_A    = 32'h0050_0000,
    parameter [31:0] C_REBUF_B    = 32'h00D0_0000,
    parameter integer C_POLL_CYC  = 150000,
    parameter integer C_DRAIN_CYC = 75000000,
    parameter integer C_DONE_HOLD_CYC = 75000000,

    parameter integer C_EXT_WORDS_EN = 0
)(
    input  wire        i_aclk,
    input  wire        i_sps0_resetn,
    output wire        o_sps0_clk,

    output wire        sps0_awvalid,
    input  wire        sps0_awready,
    output wire [3:0]  sps0_awid,
    output wire [31:0] sps0_awaddr,
    output wire [7:0]  sps0_awlen,
    output wire [2:0]  sps0_awsize,
    output wire [1:0]  sps0_awburst,
    output wire        sps0_awlock,
    output wire [3:0]  sps0_awcache,
    output wire [2:0]  sps0_awprot,
    output wire [3:0]  sps0_awqos,
    output wire        sps0_wvalid,
    input  wire        sps0_wready,
    output wire [127:0] sps0_wdata,
    output wire [15:0] sps0_wstrb,
    output wire        sps0_wlast,
    input  wire        sps0_bvalid,
    input  wire [3:0]  sps0_bid,
    input  wire [1:0]  sps0_bresp,
    output wire        sps0_bready,
    output wire        sps0_arvalid,
    input  wire        sps0_arready,
    output wire [3:0]  sps0_arid,
    output wire [31:0] sps0_araddr,
    output wire [7:0]  sps0_arlen,
    output wire [2:0]  sps0_arsize,
    output wire [1:0]  sps0_arburst,
    output wire        sps0_arlock,
    output wire [3:0]  sps0_arcache,
    output wire [2:0]  sps0_arprot,
    output wire [3:0]  sps0_arqos,
    input  wire        sps0_rvalid,
    input  wire [3:0]  sps0_rid,
    input  wire [127:0] sps0_rdata,
    input  wire [1:0]  sps0_rresp,
    input  wire        sps0_rlast,
    output wire        sps0_rready,

    output wire        o_m8_busy,
    output wire        o_m8_done,
    output wire        o_m8_err,
    output wire [31:0] o_mbox_status,
    output wire [5:0]  o_adapter_state,
    output wire        o_mbox_busy,
    output wire        o_bist_busy,
    output wire        o_bist_done,
    output wire        o_bist_pass,

    output wire        o_dbg_mux_sel,
    output wire        o_dbg_mb_ar_hs,
    output wire        o_dbg_mb_r_vld,
    output wire        o_dbg_mb_err
);

    wire rst_n_sys;
    wire rst_n_core;

    kosmo2_rst_sync_v1_0 u_rst_sync (
        .clk      (i_aclk),
        .rst_n_in (i_sps0_resetn),
        .rst_n_out(rst_n_sys)
    );

    assign o_sps0_clk = i_aclk;

    wire bist_start, bist_busy, bist_done, bist_pass;
    reg  [23:0] mbox_en_cnt;
    reg         mbox_en;

    always @(posedge i_aclk) begin
        if (!rst_n_sys) begin
            mbox_en_cnt <= 24'd0;
            mbox_en     <= 1'b0;
        end else if (!mbox_en) begin
            if (bist_done || (mbox_en_cnt >= 24'd500_000))
                mbox_en <= 1'b1;
            else
                mbox_en_cnt <= mbox_en_cnt + 24'd1;
        end
    end

    wire        mb_cmd_op;
    wire [31:0] mb_cmd_addr;
    wire [127:0] mb_cmd_wdata;
    wire [15:0] mb_cmd_wstrb;
    wire        mb_cmd_valid, mb_cmd_ready;
    wire        mb_rsp_valid, mb_rsp_err;
    wire [127:0] mb_rsp_rdata;
    wire        mb_busy;

    wire        m8_start, m8_abort;
    wire [31:0] m8_in_addr, m8_out_addr;
    wire [3:0]  m8_layer_end;
    wire        m8_skip_relu, m8_skip_pool;
    wire        m8_busy, m8_done, m8_err;

    wire        rd_busy, wr_busy;

    kosmo2_mailbox_adapter_v1_0 #(
        .C_MBOX_BASE (32'h0030_1000),
        .C_VERSION   (32'h2026_1018),
        .C_POLL_CYC  (C_POLL_CYC),
        .C_DRAIN_CYC (C_DRAIN_CYC),
        .C_DONE_HOLD_CYC(C_DONE_HOLD_CYC),
        .C_EXT_WORDS (C_EXT_WORDS_EN)
    ) u_adapter (
        .aclk           (i_aclk),
        .rst_n          (rst_n_sys & mbox_en),
        .mb_cmd_op      (mb_cmd_op),
        .mb_cmd_addr    (mb_cmd_addr),
        .mb_cmd_wdata   (mb_cmd_wdata),
        .mb_cmd_wstrb   (mb_cmd_wstrb),
        .mb_cmd_valid   (mb_cmd_valid),
        .mb_cmd_ready   (mb_cmd_ready),
        .mb_rsp_valid   (mb_rsp_valid),
        .mb_rsp_rdata   (mb_rsp_rdata),
        .mb_rsp_err     (mb_rsp_err),
        .mb_busy        (mb_busy),
        .m8_start       (m8_start),
        .m8_in_addr     (m8_in_addr),
        .m8_out_addr    (m8_out_addr),
        .m8_layer_end   (m8_layer_end),
        .m8_dbg_skip_relu(m8_skip_relu),
        .m8_dbg_skip_pool(m8_skip_pool),
        .m8_abort       (m8_abort),
        .m8_busy        (m8_busy),
        .m8_done        (m8_done),
        .m8_err         (m8_err),
        .rd_busy        (rd_busy),
        .wr_busy        (wr_busy),
        .rst_n_core     (rst_n_core),
        .dbg_state      (o_adapter_state),
        .dbg_status     (o_mbox_status)
    );

    wire [31:0] m8_rd_cmd_addr, m8_wr_cmd_addr;
    wire [23:0] m8_rd_cmd_len, m8_wr_cmd_len;
    wire        m8_rd_cmd_valid, m8_rd_cmd_ready;
    wire [127:0] m8_rd_data, m8_wr_data;
    wire        m8_rd_valid, m8_rd_last, m8_rd_ready;
    wire        m8_wr_cmd_valid, m8_wr_cmd_ready;
    wire        m8_wr_valid, m8_wr_last, m8_wr_ready;

    kosmo2_ctrl_fsm_v1_0 u_m8 (
        .aclk        (i_aclk),
        .rst_n       (rst_n_core),
        .start       (m8_start),
        .abort       (m8_abort),
        .layer_beg   (4'd0),
        .layer_end   (m8_layer_end),
        .dbg_raw     (1'b0),
        .dbg_skip_relu(m8_skip_relu),
        .dbg_skip_pool(m8_skip_pool),
        .in_addr     (m8_in_addr),
        .out_addr    (m8_out_addr),
        .rebuf_a     (C_REBUF_A),
        .rebuf_b     (C_REBUF_B),
        .busy_o      (m8_busy),
        .done_o      (m8_done),
        .err_o       (m8_err),
        .cur_layer   (),
        .cyc_cnt     (),
        .dbg_state   (),
        .rd_cmd_addr (m8_rd_cmd_addr),
        .rd_cmd_len  (m8_rd_cmd_len),
        .rd_cmd_valid(m8_rd_cmd_valid),
        .rd_cmd_ready(m8_rd_cmd_ready),
        .rd_data     (m8_rd_data),
        .rd_valid    (m8_rd_valid),
        .rd_last     (m8_rd_last),
        .rd_ready    (m8_rd_ready),
        .rd_busy     (rd_busy),
        .wr_cmd_addr (m8_wr_cmd_addr),
        .wr_cmd_len  (m8_wr_cmd_len),
        .wr_cmd_valid(m8_wr_cmd_valid),
        .wr_cmd_ready(m8_wr_cmd_ready),
        .wr_data     (m8_wr_data),
        .wr_valid    (m8_wr_valid),
        .wr_last     (m8_wr_last),
        .wr_ready    (m8_wr_ready),
        .wr_busy     (wr_busy)
    );

    wire [31:0] d_araddr, d_awaddr;
    wire [7:0]  d_arlen, d_awlen;
    wire        d_arvalid, d_arready, d_awvalid, d_awready;
    wire [127:0] d_rdata, d_wdata;
    wire [1:0]  d_rresp, d_bresp;
    wire        d_rlast, d_rvalid, d_rready;
    wire [15:0] d_wstrb;
    wire        d_wlast, d_wvalid, d_wready;
    wire        d_bvalid, d_bready;

    kosmo2_axi_dma_rd_v1_0 #(.C_DW(128), .C_MAX_BURST(16)) u_dma_rd (
        .aclk           (i_aclk),
        .rst_n          (rst_n_core),
        .cmd_base_addr  (m8_rd_cmd_addr),
        .cmd_byte_len   (m8_rd_cmd_len),
        .cmd_valid      (m8_rd_cmd_valid),
        .cmd_ready      (m8_rd_cmd_ready),
        .m_data         (m8_rd_data),
        .m_valid        (m8_rd_valid),
        .m_last         (m8_rd_last),
        .m_ready        (m8_rd_ready),
        .m_axi_araddr   (d_araddr),
        .m_axi_arlen    (d_arlen),
        .m_axi_arsize   (),
        .m_axi_arvalid  (d_arvalid),
        .m_axi_arready  (d_arready),
        .m_axi_arburst  (),
        .m_axi_arprot   (),
        .m_axi_rdata    (d_rdata),
        .m_axi_rresp    (d_rresp),
        .m_axi_rlast    (d_rlast),
        .m_axi_rvalid   (d_rvalid),
        .m_axi_rready   (d_rready),
        .busy_o         (rd_busy)
    );

    kosmo2_axi_dma_wr_v1_0 #(.C_DW(128), .C_MAX_BURST(16)) u_dma_wr (
        .aclk           (i_aclk),
        .rst_n          (rst_n_core),
        .cmd_base_addr  (m8_wr_cmd_addr),
        .cmd_byte_len   (m8_wr_cmd_len),
        .cmd_valid      (m8_wr_cmd_valid),
        .cmd_ready      (m8_wr_cmd_ready),
        .s_data         (m8_wr_data),
        .s_valid        (m8_wr_valid),
        .s_last         (m8_wr_last),
        .s_ready        (m8_wr_ready),
        .m_axi_awaddr   (d_awaddr),
        .m_axi_awlen    (d_awlen),
        .m_axi_awsize   (),
        .m_axi_awburst  (),
        .m_axi_awvalid  (d_awvalid),
        .m_axi_awready  (d_awready),
        .m_axi_awprot   (),
        .m_axi_wdata    (d_wdata),
        .m_axi_wstrb    (d_wstrb),
        .m_axi_wlast    (d_wlast),
        .m_axi_wvalid   (d_wvalid),
        .m_axi_wready   (d_wready),
        .m_axi_bresp    (d_bresp),
        .m_axi_bvalid   (d_bvalid),
        .m_axi_bready   (d_bready),
        .busy_o         (wr_busy)
    );

    wire [31:0] mb_araddr, mb_awaddr;
    wire [7:0]  mb_arlen, mb_awlen;
    wire        mb_arvalid, mb_arready, mb_awvalid, mb_awready;
    wire [127:0] mb_rdata, mb_wdata;
    wire [1:0]  mb_rresp, mb_bresp;
    wire        mb_rlast, mb_rvalid, mb_rready;
    wire [15:0] mb_wstrb;
    wire        mb_wlast, mb_wvalid, mb_wready, mb_bvalid, mb_bready;

    kosmo2_mailbox_axi_master_v1_0 u_mbaxi (
        .aclk           (i_aclk),
        .rst_n          (rst_n_core),
        .cmd_op         (mb_cmd_op),
        .cmd_addr       (mb_cmd_addr),
        .cmd_wdata      (mb_cmd_wdata),
        .cmd_wstrb      (mb_cmd_wstrb),
        .cmd_valid      (mb_cmd_valid),
        .cmd_ready      (mb_cmd_ready),
        .rsp_valid      (mb_rsp_valid),
        .rsp_rdata      (mb_rsp_rdata),
        .rsp_err        (mb_rsp_err),
        .busy_o         (mb_busy),
        .m_axi_araddr   (mb_araddr),
        .m_axi_arlen    (mb_arlen),
        .m_axi_arvalid  (mb_arvalid),
        .m_axi_arready  (mb_arready),
        .m_axi_rdata    (mb_rdata),
        .m_axi_rresp    (mb_rresp),
        .m_axi_rlast    (mb_rlast),
        .m_axi_rvalid   (mb_rvalid),
        .m_axi_rready   (mb_rready),
        .m_axi_awaddr   (mb_awaddr),
        .m_axi_awlen    (mb_awlen),
        .m_axi_awvalid  (mb_awvalid),
        .m_axi_awready  (mb_awready),
        .m_axi_wdata    (mb_wdata),
        .m_axi_wstrb    (mb_wstrb),
        .m_axi_wlast    (mb_wlast),
        .m_axi_wvalid   (mb_wvalid),
        .m_axi_wready   (mb_wready),
        .m_axi_bresp    (mb_bresp),
        .m_axi_bvalid   (mb_bvalid),
        .m_axi_bready   (mb_bready)
    );

    wire [31:0]  o_araddr, o_awaddr;
    wire [7:0]   o_arlen, o_awlen;
    wire         o_arvalid, o_arready, o_awvalid, o_awready;
    wire [127:0] o_rdata, o_wdata;
    wire [1:0]   o_rresp, o_bresp;
    wire         o_rlast, o_rvalid, o_rready;
    wire [15:0]  o_wstrb;
    wire         o_wlast, o_wvalid, o_wready, o_bvalid, o_bready;
    wire         dbg_mux_sel;

    kosmo2_axi_mux_2to1_v1_0 u_mux (
        .aclk     (i_aclk), .rst_n(rst_n_core),
        .d_araddr (d_araddr), .d_arlen(d_arlen), .d_arvalid(d_arvalid), .d_arready(d_arready),
        .d_rdata  (d_rdata), .d_rresp(d_rresp), .d_rlast(d_rlast), .d_rvalid(d_rvalid), .d_rready(d_rready),
        .d_awaddr (d_awaddr), .d_awlen(d_awlen), .d_awvalid(d_awvalid), .d_awready(d_awready),
        .d_wdata  (d_wdata), .d_wstrb(d_wstrb), .d_wlast(d_wlast), .d_wvalid(d_wvalid), .d_wready(d_wready),
        .d_bresp  (d_bresp), .d_bvalid(d_bvalid), .d_bready(d_bready),
        .m_araddr (mb_araddr), .m_arlen(mb_arlen), .m_arvalid(mb_arvalid), .m_arready(mb_arready),
        .m_rdata  (mb_rdata), .m_rresp(mb_rresp), .m_rlast(mb_rlast), .m_rvalid(mb_rvalid), .m_rready(mb_rready),
        .m_awaddr (mb_awaddr), .m_awlen(mb_awlen), .m_awvalid(mb_awvalid), .m_awready(mb_awready),
        .m_wdata  (mb_wdata), .m_wstrb(mb_wstrb), .m_wlast(mb_wlast), .m_wvalid(mb_wvalid), .m_wready(mb_wready),
        .m_bresp  (mb_bresp), .m_bvalid(mb_bvalid), .m_bready(mb_bready),
        .o_araddr (o_araddr), .o_arlen(o_arlen), .o_arvalid(o_arvalid), .o_arready(o_arready),
        .o_rdata  (o_rdata), .o_rresp(o_rresp), .o_rlast(o_rlast), .o_rvalid(o_rvalid), .o_rready(o_rready),
        .o_awaddr (o_awaddr), .o_awlen(o_awlen), .o_awvalid(o_awvalid), .o_awready(o_awready),
        .o_wdata  (o_wdata), .o_wstrb(o_wstrb), .o_wlast(o_wlast), .o_wvalid(o_wvalid), .o_wready(o_wready),
        .o_bresp  (o_bresp), .o_bvalid(o_bvalid), .o_bready(o_bready),
        .dbg_sel  (dbg_mux_sel)
    );

    assign o_dbg_mux_sel  = dbg_mux_sel;
    assign o_dbg_mb_ar_hs = o_arvalid & o_arready;
    assign o_dbg_mb_r_vld = o_rvalid  & o_rready;
    assign o_dbg_mb_err   = mb_rsp_err;

    kosmo2_ddr_access_top_v1_0 #(
        .C_DW(128), .C_IDW(4), .C_ASYNC(0)
    ) u_ddr_acc (
        .aclk_ui      (i_aclk),
        .rstn_ui      (rst_n_sys),
        .s_axi_awid   (4'd0),
        .s_axi_awaddr (o_awaddr),
        .s_axi_awlen  (o_awlen),
        .s_axi_awvalid(o_awvalid),
        .s_axi_awready(o_awready),
        .s_axi_wdata  (o_wdata),
        .s_axi_wstrb  (o_wstrb),
        .s_axi_wlast  (o_wlast),
        .s_axi_wvalid (o_wvalid),
        .s_axi_wready (o_wready),
        .s_axi_bid    (),
        .s_axi_bresp  (o_bresp),
        .s_axi_bvalid (o_bvalid),
        .s_axi_bready (o_bready),
        .s_axi_arid   (4'd0),
        .s_axi_araddr (o_araddr),
        .s_axi_arlen  (o_arlen),
        .s_axi_arvalid(o_arvalid),
        .s_axi_arready(o_arready),
        .s_axi_rid    (),
        .s_axi_rdata  (o_rdata),
        .s_axi_rresp  (o_rresp),
        .s_axi_rlast  (o_rlast),
        .s_axi_rvalid (o_rvalid),
        .s_axi_rready (o_rready),
        .sps_clk_i    (i_aclk),
        .sps_resetn_i (i_sps0_resetn),
        .m_awvalid    (sps0_awvalid),
        .m_awready    (sps0_awready),
        .m_awid       (sps0_awid),
        .m_awaddr     (sps0_awaddr),
        .m_awlen      (sps0_awlen),
        .m_awsize     (sps0_awsize),
        .m_awburst    (sps0_awburst),
        .m_awlock     (sps0_awlock),
        .m_awcache    (sps0_awcache),
        .m_awprot     (sps0_awprot),
        .m_awqos      (sps0_awqos),
        .m_wvalid     (sps0_wvalid),
        .m_wready     (sps0_wready),
        .m_wdata      (sps0_wdata),
        .m_wstrb      (sps0_wstrb),
        .m_wlast      (sps0_wlast),
        .m_bvalid     (sps0_bvalid),
        .m_bready     (sps0_bready),
        .m_bid        (sps0_bid),
        .m_bresp      (sps0_bresp),
        .m_arvalid    (sps0_arvalid),
        .m_arready    (sps0_arready),
        .m_arid       (sps0_arid),
        .m_araddr     (sps0_araddr),
        .m_arlen      (sps0_arlen),
        .m_arsize     (sps0_arsize),
        .m_arburst    (sps0_arburst),
        .m_arlock     (sps0_arlock),
        .m_arcache    (sps0_arcache),
        .m_arprot     (sps0_arprot),
        .m_arqos      (sps0_arqos),
        .m_rvalid     (sps0_rvalid),
        .m_rready     (sps0_rready),
        .m_rid        (sps0_rid),
        .m_rdata      (sps0_rdata),
        .m_rresp      (sps0_rresp),
        .m_rlast      (sps0_rlast),
        .bist_start   (bist_start),
        .bist_base    (C_BIST_BASE),
        .bist_seed    (C_BIST_SEED),
        .bist_busy    (bist_busy),
        .bist_done    (bist_done),
        .bist_pass    (bist_pass),
        .bist_err_cnt ()
    );

    reg [4:0] bist_cnt;
    always @(posedge i_aclk) begin
        if (!rst_n_sys)
            bist_cnt <= 5'd0;
        else if (bist_cnt != 5'h1F)
            bist_cnt <= bist_cnt + 5'd1;
    end
    assign bist_start = (bist_cnt == 5'd16);

    assign o_m8_busy  = m8_busy;
    assign o_m8_done  = m8_done;
    assign o_m8_err   = m8_err;
    assign o_mbox_busy= mb_busy;
    assign o_bist_busy= bist_busy;
    assign o_bist_done= bist_done;
    assign o_bist_pass= bist_pass;

endmodule
