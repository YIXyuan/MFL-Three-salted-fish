`timescale 1ns / 1ps

module kosmo2_axi_arb2_v1_0 #(
    parameter integer C_DW  = 128,
    parameter integer C_IDW = 4
)(
    input  wire              aclk,
    input  wire              rstn,

    input  wire              m0_awvalid,
    output wire              m0_awready,
    input  wire [C_IDW-1:0]  m0_awid,
    input  wire [31:0]       m0_awaddr,
    input  wire [7:0]        m0_awlen,
    input  wire              m0_wvalid,
    output wire              m0_wready,
    input  wire [C_DW-1:0]   m0_wdata,
    input  wire [C_DW/8-1:0] m0_wstrb,
    input  wire              m0_wlast,
    output wire              m0_bvalid,
    input  wire              m0_bready,
    output wire [C_IDW-1:0]  m0_bid,
    output wire [1:0]        m0_bresp,
    input  wire              m0_arvalid,
    output wire              m0_arready,
    input  wire [C_IDW-1:0]  m0_arid,
    input  wire [31:0]       m0_araddr,
    input  wire [7:0]        m0_arlen,
    output wire              m0_rvalid,
    input  wire              m0_rready,
    output wire [C_IDW-1:0]  m0_rid,
    output wire [C_DW-1:0]   m0_rdata,
    output wire [1:0]        m0_rresp,
    output wire              m0_rlast,

    input  wire              m1_awvalid,
    output wire              m1_awready,
    input  wire [C_IDW-1:0]  m1_awid,
    input  wire [31:0]       m1_awaddr,
    input  wire [7:0]        m1_awlen,
    input  wire              m1_wvalid,
    output wire              m1_wready,
    input  wire [C_DW-1:0]   m1_wdata,
    input  wire [C_DW/8-1:0] m1_wstrb,
    input  wire              m1_wlast,
    output wire              m1_bvalid,
    input  wire              m1_bready,
    output wire [C_IDW-1:0]  m1_bid,
    output wire [1:0]        m1_bresp,
    input  wire              m1_arvalid,
    output wire              m1_arready,
    input  wire [C_IDW-1:0]  m1_arid,
    input  wire [31:0]       m1_araddr,
    input  wire [7:0]        m1_arlen,
    output wire              m1_rvalid,
    input  wire              m1_rready,
    output wire [C_IDW-1:0]  m1_rid,
    output wire [C_DW-1:0]   m1_rdata,
    output wire [1:0]        m1_rresp,
    output wire              m1_rlast,

    output wire              s_awvalid,
    input  wire              s_awready,
    output wire [C_IDW-1:0]  s_awid,
    output wire [31:0]       s_awaddr,
    output wire [7:0]        s_awlen,
    output wire              s_wvalid,
    input  wire              s_wready,
    output wire [C_DW-1:0]   s_wdata,
    output wire [C_DW/8-1:0] s_wstrb,
    output wire              s_wlast,
    input  wire              s_bvalid,
    output wire              s_bready,
    input  wire [C_IDW-1:0]  s_bid,
    input  wire [1:0]        s_bresp,
    output wire              s_arvalid,
    input  wire              s_arready,
    output wire [C_IDW-1:0]  s_arid,
    output wire [31:0]       s_araddr,
    output wire [7:0]        s_arlen,
    input  wire              s_rvalid,
    output wire              s_rready,
    input  wire [C_IDW-1:0]  s_rid,
    input  wire [C_DW-1:0]   s_rdata,
    input  wire [1:0]        s_rresp,
    input  wire              s_rlast
);

    reg  w_busy, w_own;
    reg  w_wlast_seen;
    wire w_free  = !w_busy;
    wire w_take0 = w_free & m0_awvalid;
    wire w_take1 = w_free & !m0_awvalid & m1_awvalid;
    wire w_grant = s_awvalid & s_awready;

    always @(posedge aclk or negedge rstn) begin
        if (!rstn) begin
            w_busy       <= 1'b0;
            w_own        <= 1'b0;
            w_wlast_seen <= 1'b0;
        end else begin
            if (w_grant) begin
                w_busy <= 1'b1;
                w_own  <= w_take1;
            end
            if (s_wvalid & s_wready & s_wlast)
                w_wlast_seen <= 1'b1;
            if (w_busy & w_wlast_seen & s_bvalid & s_bready) begin
                w_busy       <= 1'b0;
                w_wlast_seen <= 1'b0;
            end
        end
    end

    assign s_awvalid = w_free & (m0_awvalid | m1_awvalid);
    assign s_awid    = (w_free & !m0_awvalid) ? m1_awid  : m0_awid;
    assign s_awaddr  = (w_free & !m0_awvalid) ? m1_awaddr: m0_awaddr;
    assign s_awlen   = (w_free & !m0_awvalid) ? m1_awlen : m0_awlen;
    assign m0_awready = w_take0 & s_awready;
    assign m1_awready = w_take1 & s_awready;

    wire w_owner_is0 = w_busy ? !w_own : w_take0;
    wire w_active    = w_busy | w_take0 | w_take1;
    assign s_wvalid  = w_active & (w_owner_is0 ? m0_wvalid : m1_wvalid);
    assign s_wdata   = w_owner_is0 ? m0_wdata  : m1_wdata;
    assign s_wstrb   = w_owner_is0 ? m0_wstrb  : m1_wstrb;
    assign s_wlast   = w_owner_is0 ? m0_wlast  : m1_wlast;
    assign m0_wready = w_owner_is0 & s_wready;
    assign m1_wready = !w_owner_is0 & s_wready;

    assign m0_bvalid = w_busy & !w_own & s_bvalid;
    assign m1_bvalid = w_busy &  w_own & s_bvalid;
    assign m0_bid    = s_bid;
    assign m1_bid    = s_bid;
    assign m0_bresp  = s_bresp;
    assign m1_bresp  = s_bresp;
    assign s_bready  = w_busy ? (!w_own ? m0_bready : m1_bready) : 1'b0;

    reg  r_busy, r_own;
    wire r_free  = !r_busy;
    wire r_take0 = r_free & m0_arvalid;
    wire r_take1 = r_free & !m0_arvalid & m1_arvalid;
    wire r_grant = s_arvalid & s_arready;

    always @(posedge aclk or negedge rstn) begin
        if (!rstn) begin
            r_busy <= 1'b0;
            r_own  <= 1'b0;
        end else begin
            if (r_grant) begin
                r_busy <= 1'b1;
                r_own  <= r_take1;
            end
            if (r_busy & s_rvalid & s_rready & s_rlast)
                r_busy <= 1'b0;
        end
    end

    assign s_arvalid = r_free & (m0_arvalid | m1_arvalid);
    assign s_arid    = (r_free & !m0_arvalid) ? m1_arid   : m0_arid;
    assign s_araddr  = (r_free & !m0_arvalid) ? m1_araddr : m0_araddr;
    assign s_arlen   = (r_free & !m0_arvalid) ? m1_arlen  : m0_arlen;
    assign m0_arready = r_take0 & s_arready;
    assign m1_arready = r_take1 & s_arready;

    assign m0_rvalid = r_busy & !r_own & s_rvalid;
    assign m1_rvalid = r_busy &  r_own & s_rvalid;
    assign m0_rid    = s_rid;
    assign m1_rid    = s_rid;
    assign m0_rdata  = s_rdata;
    assign m1_rdata  = s_rdata;
    assign m0_rresp  = s_rresp;
    assign m1_rresp  = s_rresp;
    assign m0_rlast  = s_rlast;
    assign m1_rlast  = s_rlast;
    assign s_rready  = r_busy ? (!r_own ? m0_rready : m1_rready) : 1'b0;

endmodule
