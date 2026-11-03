`timescale 1ns / 1ps

module kosmo2_boundary_v1_0 #(
    parameter integer C_IBUF = 2048,
    parameter integer C_OBUF = 1024
)(
    input  wire             aclk,
    input  wire             rst_n,

    input  wire             cfg_load,
    input  wire [31:0]      cfg_in_base,
    input  wire [31:0]      cfg_out_base,
    input  wire [10:0]      cfg_h,
    input  wire [10:0]      cfg_w,
    input  wire [6:0]       cfg_c,
    input  wire             cfg_pool,
    input  wire             cfg_bnd,
    input  wire             cfg_relu,
    input  wire [31:0]      cfg_mc,
    input  wire [4:0]       cfg_fshift,
    input  wire             start,

    output reg  [31:0]      rd_cmd_addr,
    output reg  [23:0]      rd_cmd_len,
    output reg              rd_cmd_valid,
    input  wire             rd_cmd_ready,
    input  wire [127:0]     rd_data,
    input  wire             rd_valid,
    input  wire             rd_last,
    output reg              rd_ready,

    output reg  [31:0]      wr_cmd_addr,
    output reg  [23:0]      wr_cmd_len,
    output reg              wr_cmd_valid,
    input  wire             wr_cmd_ready,
    output reg  [127:0]     wr_data,
    output reg              wr_valid,
    output reg              wr_last,
    input  wire             wr_ready,

    output reg              busy,
    output reg              done,
    output wire [3:0]       dbg_state
);

    localparam [3:0] S_IDLE   = 4'd0,
                     S_RDADDR = 4'd1,
                     S_RDCMD  = 4'd2,
                     S_RD     = 4'd3,
                     S_PROC   = 4'd4,
                     S_WRADDR = 4'd5,
                     S_WRCMD  = 4'd6,
                     S_WR     = 4'd7,
                     S_NEXT   = 4'd8,
                     S_DONE   = 4'd9;

    reg [3:0]  st;
    assign dbg_state = st;

    reg [10:0] h2, w2;
    reg [11:0] rd_len;

    reg [6:0]  c_cnt;
    reg [10:0] y2_cnt;
    reg [11:0] bcnt;
    reg [10:0] pi;
    reg [10:0] qidx;
    reg [10:0] woff;

    reg [7:0] ibuf [0:C_IBUF-1];
    reg [7:0] obuf [0:C_OBUF-1];

    reg               rq_v;
    reg  signed [31:0] rq_acc;
    wire              rq_q_valid;
    wire [7:0]        rq_q_out;

    kosmo2_requant_v1_0 u_rq (
        .aclk    (aclk),
        .rst_n   (rst_n),
        .in_valid(rq_v),
        .acc_in  (rq_acc),
        .mc_in   (cfg_mc),
        .fshift  (cfg_fshift),
        .relu_en (cfg_relu),
        .q_valid (rq_q_valid),
        .q_out   (rq_q_out)
    );

    wire [31:0] c32   = {25'd0, c_cnt};
    wire [31:0] h32   = {21'd0, cfg_h};
    wire [31:0] w32   = {21'd0, cfg_w};
    wire [31:0] h232  = {21'd0, h2};
    wire [31:0] w232  = {21'd0, w2};
    wire [31:0] rowin = cfg_pool ? ({21'd0, y2_cnt} << 1) : {21'd0, y2_cnt};
    wire [31:0] rd_off = (c32 * h32 + rowin) * w32;
    wire [31:0] wr_off = (c32 * h232 + {21'd0, y2_cnt}) * w232;

    wire [10:0] p2 = {pi[9:0], 1'b0};
    wire [10:0] p2w = p2 + cfg_w;
    wire signed [7:0] v00 = $signed(ibuf[p2]);
    wire signed [7:0] v01 = $signed(ibuf[p2 + 1'b1]);
    wire signed [7:0] v10 = $signed(ibuf[p2w]);
    wire signed [7:0] v11 = $signed(ibuf[p2w + 1'b1]);
    wire signed [7:0] mx0 = (v00 > v01) ? v00 : v01;
    wire signed [7:0] mx1 = (v10 > v11) ? v10 : v11;
    wire signed [7:0] vpool = (mx0 > mx1) ? mx0 : mx1;
    wire signed [7:0] vplain = $signed(ibuf[pi]);
    wire signed [7:0] vsel = cfg_pool ? vpool : vplain;

    integer j;

    always @(posedge aclk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            h2 <= 11'd0;  w2 <= 11'd0;  rd_len <= 12'd0;
            c_cnt <= 7'd0;  y2_cnt <= 11'd0;  bcnt <= 12'd0;
            pi <= 11'd0;  qidx <= 11'd0;  woff <= 11'd0;
            rd_cmd_addr <= 32'd0;  rd_cmd_len <= 24'd0;  rd_cmd_valid <= 1'b0;
            wr_cmd_addr <= 32'd0;  wr_cmd_len <= 24'd0;  wr_cmd_valid <= 1'b0;
            rd_ready <= 1'b0;  wr_valid <= 1'b0;  wr_last <= 1'b0;
            rq_v <= 1'b0;  rq_acc <= 32'sd0;
        end else begin
            done <= 1'b0;

            if (cfg_load) begin
                h2     <= cfg_pool ? (cfg_h >> 1) : cfg_h;
                w2     <= cfg_pool ? (cfg_w >> 1) : cfg_w;
                rd_len <= cfg_pool ? ({1'b0, cfg_w} << 1) : cfg_w;
            end

            case (st)

            S_IDLE: begin
                busy <= 1'b0;
                rd_cmd_valid <= 1'b0;
                wr_cmd_valid <= 1'b0;
                rd_ready <= 1'b0;
                wr_valid <= 1'b0;
                rq_v <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    c_cnt <= 7'd0;
                    y2_cnt <= 11'd0;
                    st <= S_RDADDR;
                end
            end

            S_RDADDR: begin
                rd_cmd_addr  <= cfg_in_base + rd_off;
                rd_cmd_len   <= {12'd0, rd_len};
                rd_cmd_valid <= 1'b0;
                bcnt <= 12'd0;
                pi   <= 11'd0;
                qidx <= 11'd0;
                st <= S_RDCMD;
            end
            S_RDCMD: begin
                rd_cmd_valid <= 1'b1;

                if (rd_cmd_valid && rd_cmd_ready) begin
                    rd_cmd_valid <= 1'b0;
                    rd_ready <= 1'b1;
                    st <= S_RD;
                end
            end

            S_RD: begin
                if (rd_valid && rd_ready) begin
                    for (j = 0; j < 16; j = j + 1)
                        ibuf[bcnt + j] <= rd_data[j*8 +: 8];
                    bcnt <= bcnt + 12'd16;
                    if (rd_last) begin
                        rd_ready <= 1'b0;
                        st <= S_PROC;
                    end
                end
            end

            S_PROC: begin
                if (pi < w2) begin
                    rq_v   <= 1'b1;
                    rq_acc <= {{24{vsel[7]}}, vsel};
                    pi     <= pi + 1'b1;
                end else begin
                    rq_v <= 1'b0;
                end
                if (rq_q_valid) begin
                    obuf[qidx] <= rq_q_out;
                    qidx <= qidx + 1'b1;
                    if (qidx == w2 - 1'b1) begin
                        rq_v <= 1'b0;
                        st <= S_WRADDR;
                    end
                end
            end

            S_WRADDR: begin
                wr_cmd_addr  <= cfg_out_base + wr_off;
                wr_cmd_len   <= {13'd0, w2};
                wr_cmd_valid <= 1'b0;
                woff <= 11'd0;
                st <= S_WRCMD;
            end
            S_WRCMD: begin
                wr_cmd_valid <= 1'b1;
                if (wr_cmd_valid && wr_cmd_ready) begin
                    wr_cmd_valid <= 1'b0;
                    st <= S_WR;
                end
            end

            S_WR: begin
                if (!wr_valid) begin
                    for (j = 0; j < 16; j = j + 1)
                        wr_data[j*8 +: 8] <= obuf[woff + j];
                    wr_last  <= ((woff + 11'd16) >= w2);
                    wr_valid <= 1'b1;
                end else if (wr_ready) begin
                    wr_valid <= 1'b0;
                    if ((woff + 11'd16) >= w2)
                        st <= S_NEXT;
                    else
                        woff <= woff + 11'd16;
                end
            end

            S_NEXT: begin
                if (y2_cnt == h2 - 1'b1) begin
                    y2_cnt <= 11'd0;
                    if (c_cnt == cfg_c - 1'b1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        st <= S_DONE;
                    end else begin
                        c_cnt <= c_cnt + 1'b1;
                        st <= S_RDADDR;
                    end
                end else begin
                    y2_cnt <= y2_cnt + 1'b1;
                    st <= S_RDADDR;
                end
            end
            S_DONE: begin
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
