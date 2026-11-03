`timescale 1ns / 1ps

module kosmo2_axi_mux_2to1_v1_0 (
    input  wire             aclk,
    input  wire             rst_n,

    input  wire [31:0]      d_araddr,
    input  wire [7:0]       d_arlen,
    input  wire             d_arvalid,
    output wire             d_arready,
    output wire [127:0]     d_rdata,
    output wire [1:0]       d_rresp,
    output wire             d_rlast,
    output wire             d_rvalid,
    input  wire             d_rready,
    input  wire [31:0]      d_awaddr,
    input  wire [7:0]       d_awlen,
    input  wire             d_awvalid,
    output wire             d_awready,
    input  wire [127:0]     d_wdata,
    input  wire [15:0]      d_wstrb,
    input  wire             d_wlast,
    input  wire             d_wvalid,
    output wire             d_wready,
    output wire [1:0]       d_bresp,
    output wire             d_bvalid,
    input  wire             d_bready,

    input  wire [31:0]      m_araddr,
    input  wire [7:0]       m_arlen,
    input  wire             m_arvalid,
    output wire             m_arready,
    output wire [127:0]     m_rdata,
    output wire [1:0]       m_rresp,
    output wire             m_rlast,
    output wire             m_rvalid,
    input  wire             m_rready,
    input  wire [31:0]      m_awaddr,
    input  wire [7:0]       m_awlen,
    input  wire             m_awvalid,
    output wire             m_awready,
    input  wire [127:0]     m_wdata,
    input  wire [15:0]      m_wstrb,
    input  wire             m_wlast,
    input  wire             m_wvalid,
    output wire             m_wready,
    output wire [1:0]       m_bresp,
    output wire             m_bvalid,
    input  wire             m_bready,

    output wire [31:0]      o_araddr,
    output wire [7:0]       o_arlen,
    output wire             o_arvalid,
    input  wire             o_arready,
    input  wire [127:0]     o_rdata,
    input  wire [1:0]       o_rresp,
    input  wire             o_rlast,
    input  wire             o_rvalid,
    output wire             o_rready,
    output wire [31:0]      o_awaddr,
    output wire [7:0]       o_awlen,
    output wire             o_awvalid,
    input  wire             o_awready,
    output wire [127:0]     o_wdata,
    output wire [15:0]      o_wstrb,
    output wire             o_wlast,
    output wire             o_wvalid,
    input  wire             o_wready,
    input  wire [1:0]       o_bresp,
    input  wire             o_bvalid,
    output wire             o_bready,

    output wire             dbg_sel
);

    reg sel;
    reg rd_out;
    reg wr_out;

    assign dbg_sel = sel;

    assign o_araddr  = sel ? m_araddr : d_araddr;
    assign o_arlen   = sel ? m_arlen  : d_arlen;
    assign o_arvalid = sel ? m_arvalid: d_arvalid;
    assign o_awaddr  = sel ? m_awaddr : d_awaddr;
    assign o_awlen   = sel ? m_awlen  : d_awlen;
    assign o_awvalid = sel ? m_awvalid: d_awvalid;
    assign o_wdata   = sel ? m_wdata  : d_wdata;
    assign o_wstrb   = sel ? m_wstrb  : d_wstrb;
    assign o_wlast   = sel ? m_wlast  : d_wlast;
    assign o_wvalid  = sel ? m_wvalid : d_wvalid;
    assign o_rready  = sel ? m_rready : d_rready;
    assign o_bready  = sel ? m_bready : d_bready;

    assign d_arready = sel ? 1'b0 : o_arready;
    assign m_arready = sel ? o_arready : 1'b0;
    assign d_awready = sel ? 1'b0 : o_awready;
    assign m_awready = sel ? o_awready : 1'b0;
    assign d_wready  = sel ? 1'b0 : o_wready;
    assign m_wready  = sel ? o_wready : 1'b0;

    assign d_rdata  = sel ? 128'd0 : o_rdata;
    assign d_rresp  = sel ? 2'b00  : o_rresp;
    assign d_rlast  = sel ? 1'b0   : o_rlast;
    assign d_rvalid = sel ? 1'b0   : o_rvalid;
    assign m_rdata  = sel ? o_rdata : 128'd0;
    assign m_rresp  = sel ? o_rresp : 2'b00;
    assign m_rlast  = sel ? o_rlast : 1'b0;
    assign m_rvalid = sel ? o_rvalid: 1'b0;

    assign d_bresp  = sel ? 2'b00  : o_bresp;
    assign d_bvalid = sel ? 1'b0   : o_bvalid;
    assign m_bresp  = sel ? o_bresp : 2'b00;
    assign m_bvalid = sel ? o_bvalid: 1'b0;

    wire d_ar_fire = d_arvalid && d_arready;
    wire m_ar_fire = m_arvalid && m_arready;
    wire d_aw_fire = d_awvalid && d_awready;
    wire m_aw_fire = m_awvalid && m_awready;

    wire r_fire_last = o_rvalid && o_rready && o_rlast;
    wire b_fire      = o_bvalid && o_bready;

    wire data_no_req = !(d_arvalid || d_awvalid || d_wvalid);
    wire mb_req      = (m_arvalid || m_awvalid);

    wire sel_ar_fire = (sel == 1'b0) ? (d_arvalid && o_arready)
                                     : (m_arvalid && o_arready);
    wire sel_aw_fire = (sel == 1'b0) ? (d_awvalid && o_awready)
                                     : (m_awvalid && o_awready);
    wire rd_out_nxt = sel_ar_fire ? 1'b1 : (r_fire_last ? 1'b0 : rd_out);
    wire wr_out_nxt = sel_aw_fire ? 1'b1 : (b_fire      ? 1'b0 : wr_out);

    always @(posedge aclk) begin
        if (!rst_n) begin
            sel    <= 1'b0;
            rd_out <= 1'b0;
            wr_out <= 1'b0;
        end else begin

            if ((sel == 1'b0 && d_ar_fire) || (sel == 1'b1 && m_ar_fire))
                rd_out <= 1'b1;
            else if (r_fire_last)
                rd_out <= 1'b0;

            if ((sel == 1'b0 && d_aw_fire) || (sel == 1'b1 && m_aw_fire))
                wr_out <= 1'b1;
            else if (b_fire)
                wr_out <= 1'b0;

            if (sel == 1'b0) begin
                if (mb_req && !rd_out_nxt && !wr_out_nxt && data_no_req)
                    sel <= 1'b1;
            end else begin

                if (!rd_out_nxt && !wr_out_nxt && !mb_req)
                    sel <= 1'b0;
            end
        end
    end

endmodule
