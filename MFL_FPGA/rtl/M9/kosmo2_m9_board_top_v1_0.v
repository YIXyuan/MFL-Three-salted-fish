module kosmo2_m9_board_top_v1_0 (
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
    output wire        o_bist_done,
    output wire        o_bist_pass
);

    wire       dbg_m8_busy, dbg_m8_done, dbg_m8_err;
    wire       dbg_bist_done_pulse, dbg_bist_pass_q;
    reg        dbg_bist_done_sticky;

    kosmo2_m9_top_v1_0 #(
        .C_EXT_WORDS_EN (1),
        .C_BIST_BASE    (32'h00C8_0000),
        .C_REBUF_A      (32'h0050_0000),
        .C_REBUF_B      (32'h00D0_0000),
        .C_POLL_CYC     (50000),
        .C_DRAIN_CYC    (25000000),
        .C_DONE_HOLD_CYC(25000000)
    ) u_m9 (
        .i_aclk         (i_aclk),

        .o_mbox_status  (),
        .o_adapter_state(),
        .o_mbox_busy    (),
        .o_bist_busy    (),
        .o_dbg_mux_sel  (),
        .o_dbg_mb_ar_hs (),
        .o_dbg_mb_r_vld (),
        .o_dbg_mb_err   (),

        .i_sps0_resetn  (i_sps0_resetn),
        .o_sps0_clk     (o_sps0_clk),
        .sps0_awvalid   (sps0_awvalid),
        .sps0_awready   (sps0_awready),
        .sps0_awid      (sps0_awid   ),
        .sps0_awlock    (sps0_awlock ),
        .sps0_awcache   (sps0_awcache),
        .sps0_awprot    (sps0_awprot ),
        .sps0_awqos     (sps0_awqos  ),
        .sps0_wvalid    (sps0_wvalid ),
        .sps0_wready    (sps0_wready ),
        .sps0_wdata     (sps0_wdata  ),
        .sps0_wstrb     (sps0_wstrb  ),
        .sps0_wlast     (sps0_wlast  ),
        .sps0_bvalid    (sps0_bvalid ),
        .sps0_bid       (sps0_bid    ),
        .sps0_bresp     (sps0_bresp  ),
        .sps0_bready    (sps0_bready ),
        .sps0_arvalid   (sps0_arvalid),
        .sps0_arready   (sps0_arready),
        .sps0_arid      (sps0_arid   ),
        .sps0_araddr    (sps0_araddr ),
        .sps0_arlen     (sps0_arlen  ),
        .sps0_arsize    (sps0_arsize ),
        .sps0_arburst   (sps0_arburst),
        .sps0_arlock    (sps0_arlock ),
        .sps0_arcache   (sps0_arcache),
        .sps0_arprot    (sps0_arprot ),
        .sps0_arqos     (sps0_arqos  ),
        .sps0_rvalid    (sps0_rvalid ),
        .sps0_rid       (sps0_rid    ),
        .sps0_rdata     (sps0_rdata  ),
        .sps0_rresp     (sps0_rresp  ),
        .sps0_rlast     (sps0_rlast  ),
        .sps0_rready    (sps0_rready ),
        .sps0_awaddr    (sps0_awaddr ),
        .sps0_awlen     (sps0_awlen  ),
        .sps0_awsize    (sps0_awsize ),
        .sps0_awburst   (sps0_awburst),
        .o_m8_busy      (dbg_m8_busy),
        .o_m8_done      (dbg_m8_done),
        .o_m8_err       (dbg_m8_err),
        .o_bist_done    (dbg_bist_done_pulse),
        .o_bist_pass    (dbg_bist_pass_q)
    );

    always @(posedge i_aclk or negedge i_sps0_resetn) begin
        if (!i_sps0_resetn)
            dbg_bist_done_sticky <= 1'b0;
        else if (dbg_bist_done_pulse)
            dbg_bist_done_sticky <= 1'b1;
    end

    assign o_m8_busy   = dbg_m8_busy;
    assign o_m8_done   = dbg_m8_done;
    assign o_m8_err    = dbg_m8_err;
    assign o_bist_done = dbg_bist_done_sticky;
    assign o_bist_pass = dbg_bist_pass_q;

endmodule
