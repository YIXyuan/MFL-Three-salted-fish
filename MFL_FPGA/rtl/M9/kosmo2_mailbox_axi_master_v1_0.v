`timescale 1ns / 1ps

module kosmo2_mailbox_axi_master_v1_0 #(
    parameter integer C_TIMEOUT = 150000
)(
    input  wire             aclk,
    input  wire             rst_n,

    input  wire             cmd_op,
    input  wire [31:0]      cmd_addr,
    input  wire [127:0]     cmd_wdata,
    input  wire [15:0]      cmd_wstrb,
    input  wire             cmd_valid,
    output reg              cmd_ready,
    output reg              rsp_valid,
    output reg  [127:0]     rsp_rdata,
    output reg              rsp_err,
    output wire             busy_o,

    output reg  [31:0]      m_axi_araddr,
    output reg  [7:0]       m_axi_arlen,
    output reg              m_axi_arvalid,
    input  wire             m_axi_arready,

    input  wire [127:0]     m_axi_rdata,
    input  wire [1:0]       m_axi_rresp,
    input  wire             m_axi_rlast,
    input  wire             m_axi_rvalid,
    output reg              m_axi_rready,

    output reg  [31:0]      m_axi_awaddr,
    output reg  [7:0]       m_axi_awlen,
    output reg              m_axi_awvalid,
    input  wire             m_axi_awready,

    output reg  [127:0]     m_axi_wdata,
    output reg  [15:0]      m_axi_wstrb,
    output reg              m_axi_wlast,
    output reg              m_axi_wvalid,
    input  wire             m_axi_wready,

    input  wire [1:0]       m_axi_bresp,
    input  wire             m_axi_bvalid,
    output reg              m_axi_bready
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_AR   = 3'd1,
                     S_R    = 3'd2,
                     S_AW   = 3'd3,
                     S_W    = 3'd4,
                     S_B    = 3'd5,
                     S_RSP  = 3'd6,
                     S_DRAIN= 3'd7;

    reg [2:0]  st;
    reg        op_r;
    reg [31:0] tcnt;

    assign busy_o = (st != S_IDLE) && (st != S_RSP);

    always @(posedge aclk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            cmd_ready <= 1'b1;
            rsp_valid <= 1'b0;
            rsp_rdata <= 128'd0;
            rsp_err   <= 1'b0;
            m_axi_araddr <= 32'd0;  m_axi_arlen <= 8'd0;  m_axi_arvalid <= 1'b0;
            m_axi_rready <= 1'b0;
            m_axi_awaddr <= 32'd0;  m_axi_awlen <= 8'd0;  m_axi_awvalid <= 1'b0;
            m_axi_wdata <= 128'd0;  m_axi_wstrb <= 16'd0;
            m_axi_wlast <= 1'b0;    m_axi_wvalid <= 1'b0;
            m_axi_bready <= 1'b0;
            op_r <= 1'b0;  tcnt <= 32'd0;
        end else begin
            rsp_valid <= 1'b0;

            case (st)
            S_IDLE: begin
                cmd_ready <= 1'b1;
                tcnt <= 32'd0;
                if (cmd_valid && cmd_ready) begin
                    cmd_ready <= 1'b0;
                    op_r <= cmd_op;
                    if (cmd_op == 1'b0) begin
                        m_axi_araddr  <= cmd_addr;
                        m_axi_arlen   <= 8'd0;
                        m_axi_arvalid <= 1'b1;
                        st <= S_AR;
                    end else begin
                        m_axi_awaddr  <= cmd_addr;
                        m_axi_awlen   <= 8'd0;
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata   <= cmd_wdata;
                        m_axi_wstrb   <= cmd_wstrb;
                        m_axi_wlast   <= 1'b1;
                        st <= S_AW;
                    end
                end
            end
            S_AR: begin
                if (m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b1;
                    st <= S_R;
                end
            end
            S_R: begin
                if (m_axi_rvalid && m_axi_rready) begin
                    rsp_rdata <= m_axi_rdata;
                    if (m_axi_rresp != 2'b00) rsp_err <= 1'b1; else rsp_err <= 1'b0;
                    if (m_axi_rlast) begin
                        m_axi_rready <= 1'b0;
                        st <= S_RSP;
                    end
                end
            end
            S_AW: begin
                if (m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b1;
                    st <= S_W;
                end
            end
            S_W: begin
                if (m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    m_axi_wlast  <= 1'b0;
                    m_axi_bready <= 1'b1;
                    st <= S_B;
                end
            end
            S_B: begin
                if (m_axi_bvalid) begin
                    m_axi_bready <= 1'b0;
                    if (m_axi_bresp != 2'b00) rsp_err <= 1'b1; else rsp_err <= 1'b0;
                    st <= S_RSP;
                end
            end
            S_RSP: begin
                rsp_valid <= 1'b1;
                st <= S_IDLE;
            end

            S_DRAIN: begin
                if ((m_axi_rvalid && m_axi_rlast) || m_axi_bvalid) begin
                    m_axi_rready <= 1'b0;
                    m_axi_bready <= 1'b0;
                    st <= S_RSP;
                end else if (tcnt >= C_TIMEOUT) begin
                    m_axi_rready <= 1'b0;
                    m_axi_bready <= 1'b0;
                    st <= S_RSP;
                end else
                    tcnt <= tcnt + 32'd1;
            end
            default: st <= S_IDLE;
            endcase

            if (st != S_IDLE && st != S_RSP && st != S_DRAIN) begin
                if (tcnt >= C_TIMEOUT) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_rready  <= 1'b1;
                    m_axi_bready  <= 1'b1;
                    rsp_err   <= 1'b1;
                    rsp_rdata <= 128'd0;
                    tcnt      <= 32'd0;
                    st <= S_DRAIN;
                end else
                    tcnt <= tcnt + 32'd1;
            end
        end
    end

endmodule
