`timescale 1ns / 1ps

module kosmo2_maxpool_v1_0 #(
    parameter integer C_CH_MAX     = 96,
    parameter integer C_YBUF_WORDS = 512,
    parameter integer C_X_BITS     = 10
)(
    input  wire                     aclk,
    input  wire                     rst_n,

    input  wire [C_X_BITS-1:0]      cfg_w,
    input  wire [6:0]               cfg_c,
    input  wire [C_X_BITS-1:0]      cfg_h,
    input  wire                     cfg_load,

    input  wire [C_CH_MAX*8-1:0]    s_data,
    input  wire                     s_valid,
    output wire                     s_ready,

    output reg  [C_CH_MAX*8-1:0]    m_data,
    output reg                      m_valid,
    input  wire                     m_ready,

    output wire [2:0]               dbg_state
);

    localparam [2:0] S_EVEN = 3'd0;
    localparam [2:0] S_ODD  = 3'd1;
    localparam [2:0] S_RD   = 3'd2;
    localparam [2:0] S_EM   = 3'd3;
    localparam [2:0] S_EMIT = 3'd4;

    reg [2:0]            state;
    reg [7:0]            px_even [0:C_CH_MAX-1];
    reg [C_CH_MAX*8-1:0] mx_r;
    reg [C_CH_MAX*8-1:0] ybuf_q;
    reg [C_X_BITS-1:0]   x2_cnt;
    reg [C_X_BITS-1:0]   y_cnt;
    reg                  row_odd;

    wire row_even = !row_odd;
    wire x2_last  = (x2_cnt == ((cfg_w >> 1) - 1'b1));

    genvar g;
    wire [C_CH_MAX*8-1:0] mx_v;
    generate
        for (g = 0; g < C_CH_MAX; g = g + 1) begin : G_MX
            assign mx_v[g*8 +: 8] = (g >= cfg_c) ? 8'h00 :
                                    (($signed(px_even[g]) > $signed(s_data[g*8 +: 8]))
                                    ? px_even[g] : s_data[g*8 +: 8]);
        end
    endgenerate

    wire [C_CH_MAX*8-1:0] mout_v;
    generate
        for (g = 0; g < C_CH_MAX; g = g + 1) begin : G_MO
            assign mout_v[g*8 +: 8] = (g >= cfg_c) ? 8'h00 :
                                      (($signed(mx_r[g*8 +: 8]) > $signed(ybuf_q[g*8 +: 8]))
                                      ? mx_r[g*8 +: 8] : ybuf_q[g*8 +: 8]);
        end
    endgenerate

    assign s_ready   = (state == S_EVEN) || (state == S_ODD);
    assign dbg_state = state;

    reg [C_CH_MAX*8-1:0] ybuf [0:C_YBUF_WORDS-1];

    integer gi;
    always @(posedge aclk) begin
        if (!rst_n) begin
            state   <= S_EVEN;
            x2_cnt  <= {C_X_BITS{1'b0}};
            y_cnt   <= {C_X_BITS{1'b0}};
            row_odd <= 1'b0;
            m_valid <= 1'b0;
        end else begin
            if (cfg_load) begin
                x2_cnt  <= {C_X_BITS{1'b0}};
                y_cnt   <= {C_X_BITS{1'b0}};
                row_odd <= 1'b0;
                state   <= S_EVEN;
                m_valid <= 1'b0;
            end else begin
                case (state)

                S_EVEN: begin
                    if (s_valid) begin
                        for (gi = 0; gi < C_CH_MAX; gi = gi + 1)
                            px_even[gi] <= s_data[gi*8 +: 8];
                        state <= S_ODD;
                    end
                end

                S_ODD: begin
                    if (s_valid) begin
                        mx_r <= mx_v;
                        if (row_even) begin

                            ybuf[x2_cnt] <= mx_v;
                            x2_cnt <= x2_cnt + 1'b1;
                            if (x2_last) begin
                                x2_cnt  <= {C_X_BITS{1'b0}};
                                y_cnt   <= y_cnt + 1'b1;
                                row_odd <= ~row_odd;
                            end
                            state <= S_EVEN;
                        end else begin
                            state <= S_RD;
                        end
                    end
                end

                S_RD: begin
                    ybuf_q <= ybuf[x2_cnt];
                    state  <= S_EM;
                end

                S_EM: begin
                    m_data  <= mout_v;
                    m_valid <= 1'b1;
                    state   <= S_EMIT;
                end

                S_EMIT: begin
                    if (m_ready) begin
                        m_valid <= 1'b0;
                        x2_cnt  <= x2_cnt + 1'b1;
                        if (x2_last) begin
                            x2_cnt  <= {C_X_BITS{1'b0}};
                            y_cnt   <= y_cnt + 1'b1;
                            row_odd <= ~row_odd;
                        end
                        state <= S_EVEN;
                    end
                end
                default: state <= S_EVEN;
                endcase
            end
        end
    end

endmodule
