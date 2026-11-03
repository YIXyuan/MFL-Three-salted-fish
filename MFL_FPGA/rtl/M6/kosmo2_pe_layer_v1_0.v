`timescale 1ns / 1ps

module kosmo2_pe_layer_v1_0 #(
    parameter integer C_CH_MAX    = 96,
    parameter integer C_X_BITS    = 11,
    parameter integer C_ROW_BYTES = 16384
)(
    input  wire                    aclk,
    input  wire                    rst_n,

    input  wire [6:0]              cfg_in_ch,
    input  wire [6:0]              cfg_out_ch,
    input  wire [C_X_BITS-1:0]     cfg_w,
    input  wire [C_X_BITS-1:0]     cfg_h,
    input  wire [3:0]              cfg_bank_id,
    input  wire                    cfg_relu_en,
    input  wire [31:0]             cfg_rd_base,
    input  wire [31:0]             cfg_wr_base,
    input  wire                    cfg_load,

    output wire [3:0]              w_bank,
    output wire [9:0]              w_col_idx,
    input  wire [2047:0]           w_col,
    input  wire [8191:0]           bias_line,
    input  wire [8191:0]           mc_line,

    output reg                     rd_req,
    output reg  [31:0]             rd_req_addr,
    output reg  [C_X_BITS-1:0]     rd_req_len,
    input  wire [127:0]            rd_data,
    input  wire                    rd_valid,
    output wire                    rd_ready,

    output reg                     wr_req,
    output reg  [31:0]             wr_req_addr,
    output reg  [C_X_BITS-1:0]     wr_req_len,
    output reg  [127:0]            wr_data,
    output reg                     wr_valid,
    input  wire                    wr_ready,

    output wire                    busy_o,
    output reg                     done_o,
    output wire [2:0]              dbg_state,
    output wire [C_X_BITS-1:0]     dbg_x,
    output wire [C_X_BITS-1:0]     dbg_y
);

    localparam [2:0] S_IDLE  = 3'd0,
                     S_CFG   = 3'd1,
                     S_LD    = 3'd2,
                     S_PIX   = 3'd3,
                     S_ROWWR = 3'd4,
                     S_DONE  = 3'd5;
    reg [2:0] st;
    assign dbg_state = st;

    reg [6:0]             in_ch_l, out_ch_l;
    reg [C_X_BITS-1:0]    w_l, h_l;
    reg                   relu_l;
    reg [31:0]            rd_base_l, wr_base_l;
    reg [3:0]             bank_id_l;
    reg [8191:0]          bias_latch, mc_latch;
    reg [2*C_X_BITS:0]    hp_l;
    reg [C_X_BITS+2:0]    wp_l;
    reg [C_X_BITS+2:0]    ph_max;

    reg [C_X_BITS-1:0] o_cur, x_cur;
    reg [C_X_BITS+2:0] ph;
    reg [1:0]          bank0_cnt;
    reg [1:0]          ldbank_cnt;
    reg [6:0]          qc;
    reg                pre_mode;
    reg [C_X_BITS-1:0] r_cur;
    reg [6:0]          c_cur;
    reg                ld_sub;
    reg [C_X_BITS-1:0] bytes_fed;
    reg                beat_full;
    reg [127:0]        beat_r;
    reg [C_X_BITS-1:0] seg_c, byte_i;
    reg [3:0]          pcnt;
    reg [127:0]        pack_r;
    reg                seg_start;
    reg [1:0]          kyi, kwi;
    reg [6:0]          cini;
    reg [3:0]          cfg_cnt;

    wire                 lb_cfg_load;
    wire                 lb_ld_start;
    wire [1:0]           lb_ld_bank;
    wire [6:0]           lb_ld_ch;
    wire                 lb_ld_valid;
    wire                 lb_ld_ready;
    wire [7:0]           lb_ld_data;
    wire                 lb_ld_done;
    wire                 lb_rd_valid;
    wire [1:0]           lb_rd_bank0;
    wire [2:0]           lb_rd_row_ok;
    wire [1:0]           lb_rd_ky, lb_rd_kw;
    wire [6:0]           lb_rd_cin;
    wire [C_X_BITS-1:0]  lb_rd_x;
    wire [7:0]           lb_rd_data;
    wire                 lb_rd_data_vld;
    wire                 m4_acc_out_vld;
    wire signed [31:0]   m4_acc_out;
    reg                  rq_v;
    reg  [7:0]           rq_c;
    wire                 rq_q_valid;
    wire [7:0]           rq_q_out;

    reg [7:0] rowbuf [0:C_ROW_BYTES-1];

    wire [11:0] tap12 = ((({10'd0, kyi} * 10'd3) + {10'd0, kwi}) * in_ch_l) + {5'd0, cini};
    assign w_col_idx = tap12[9:0];

    wire [C_X_BITS+7:0] rb_wr_idx = x_cur * out_ch_l;
    wire [C_X_BITS+7:0] rb_rd_idx = byte_i * out_ch_l;

    wire ph_scan = (st == S_PIX) && (ph >= 13'd1) && (ph <= {1'b0, wp_l});
    wire ph_en   = (st == S_PIX) && (ph >= 13'd3) && (ph <= {1'b0, wp_l} + 13'd2);
    wire ph_rd   = (st == S_PIX) && (ph >= {1'b0, wp_l} + 13'd3) &&
                   (ph <= {1'b0, wp_l} + 13'd2 + {6'd0, out_ch_l});
    wire acc_ld  = (st == S_PIX) && (ph == 13'd0);
    wire [7:0] c_read_c = ph_rd ? (ph[9:0] - wp_l[9:0] - 10'd3) : 8'd0;

    wire [2:0] row_ok_c = { ({1'b0, o_cur} + 11'd2 <= {1'b0, h_l}),
                            ({1'b0, o_cur} + 11'd1 <= {1'b0, h_l}),
                            (o_cur >= 10'd1) && (o_cur <= h_l) };

    kosmo2_line_buffer_v1_0 #(
        .C_ROW_BYTES (C_ROW_BYTES),
        .C_CH_BITS   (7),
        .C_X_BITS    (C_X_BITS)
    ) u_lb (
        .aclk       (aclk),
        .rst_n      (rst_n),
        .cfg_w      (w_l),
        .cfg_c      (in_ch_l),
        .cfg_load   (lb_cfg_load),
        .ld_start   (lb_ld_start),
        .ld_bank    (lb_ld_bank),
        .ld_ch      (lb_ld_ch),
        .ld_valid   (lb_ld_valid),
        .ld_ready   (lb_ld_ready),
        .ld_data    (lb_ld_data),
        .ld_done    (lb_ld_done),
        .rd_valid   (lb_rd_valid),
        .rd_bank0   (lb_rd_bank0),
        .rd_row_ok  (lb_rd_row_ok),
        .rd_ky      (lb_rd_ky),
        .rd_kw      (lb_rd_kw),
        .rd_cin     (lb_rd_cin),
        .rd_x       (lb_rd_x),
        .rd_data    (lb_rd_data),
        .rd_data_vld(lb_rd_data_vld),
        .dbg_bank   ()
    );
    assign lb_cfg_load = (st == S_CFG) && (cfg_cnt == 4'd2);
    assign lb_ld_start = (st == S_LD) && (ld_sub == 1'b0);
    assign lb_ld_bank  = ldbank_cnt;
    assign lb_ld_ch    = c_cur;
    assign lb_ld_valid = (st == S_LD) && (ld_sub == 1'b1) && beat_full &&
                         (bytes_fed < w_l);
    assign lb_ld_data  = beat_r[bytes_fed[3:0]*8 +: 8];
    assign lb_rd_valid   = ph_scan;
    assign lb_rd_bank0   = bank0_cnt;
    assign lb_rd_row_ok  = row_ok_c;
    assign lb_rd_ky      = kyi;
    assign lb_rd_kw      = kwi;
    assign lb_rd_cin     = cini;
    assign lb_rd_x       = x_cur;

    kosmo2_mac_array_v1_0 #(.C_OC(256)) u_mac (
        .aclk       (aclk),
        .rst_n      (rst_n),
        .pix_bcast  (lb_rd_data),
        .w_col      (w_col),
        .bias_line  (bias_latch),
        .acc_ld     (acc_ld),
        .acc_en     (ph_en),
        .acc_rd     (ph_rd),
        .c_read     (c_read_c),
        .acc_out    (m4_acc_out),
        .acc_out_vld(m4_acc_out_vld),
        .busy_o     ()
    );

    reg [31:0] mc_sel_r;
    always @(posedge aclk) begin
        if (!rst_n) mc_sel_r <= 32'd0;
        else        mc_sel_r <= mc_latch[c_read_c*32 +: 32];
    end

    kosmo2_requant_v1_0 u_rq (
        .aclk    (aclk),
        .rst_n   (rst_n),
        .in_valid(rq_v),
        .acc_in  (m4_acc_out),
        .mc_in   (mc_sel_r),
        .fshift  (5'd31),
        .relu_en (relu_l),
        .q_valid (rq_q_valid),
        .q_out   (rq_q_out)
    );

    always @(posedge aclk) begin
        if (!rst_n) begin
            qc <= 7'd0;
        end else begin
            if (rq_q_valid) begin
                rowbuf[rb_wr_idx + {{(C_X_BITS-7){1'b0}}, qc}] <= rq_q_out;
                qc <= qc + 7'd1;
            end else if ((st == S_PIX) && (ph == 13'd0)) begin
                qc <= 7'd0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            done_o <= 1'b0;
            rd_req <= 1'b0;  rd_req_len <= {C_X_BITS{1'b0}};
            wr_req <= 1'b0;  wr_valid <= 1'b0;  wr_req_len <= {C_X_BITS{1'b0}};
            wr_data <= 128'd0;  wr_req_addr <= 32'd0;
            rq_v <= 1'b0;  rq_c <= 7'd0;
            o_cur <= {C_X_BITS{1'b0}};  x_cur <= {C_X_BITS{1'b0}};  ph <= 13'd0;
            bank0_cnt <= 2'd2;  ldbank_cnt <= 2'd0;
            pre_mode <= 1'b1;  r_cur <= {C_X_BITS{1'b0}};  c_cur <= 7'd0;
            ld_sub <= 1'b0;  bytes_fed <= {C_X_BITS{1'b0}};  beat_full <= 1'b0;
            seg_c <= {C_X_BITS{1'b0}};  byte_i <= {C_X_BITS{1'b0}};
            pcnt <= 4'd0;  seg_start <= 1'b0;  cfg_cnt <= 4'd0;
            kyi <= 2'd0;  kwi <= 2'd0;  cini <= 7'd0;
        end else begin
            done_o <= 1'b0;
            rd_req <= 1'b0;
            wr_req <= 1'b0;
            case (st)

            S_IDLE: begin
                x_cur <= {C_X_BITS{1'b0}};  o_cur <= {C_X_BITS{1'b0}};  ph <= 13'd0;
                bank0_cnt <= 2'd2;  ldbank_cnt <= 2'd0;
                if (cfg_load) begin
                    in_ch_l <= cfg_in_ch;  out_ch_l <= cfg_out_ch;
                    w_l <= cfg_w;  h_l <= cfg_h;
                    relu_l <= cfg_relu_en;  bank_id_l <= cfg_bank_id;
                    rd_base_l <= cfg_rd_base;  wr_base_l <= cfg_wr_base;
                    hp_l <= cfg_h * cfg_w;
                    wp_l <= 13'd9 * cfg_in_ch;
                    ph_max <= (13'd9 * cfg_in_ch) + {6'd0, cfg_out_ch} + 13'd5;
                    cfg_cnt <= 4'd0;
                    st <= S_CFG;
                end
            end

            S_CFG: begin
                cfg_cnt <= cfg_cnt + 4'd1;
                if (cfg_cnt == 4'd1) begin
                    bias_latch <= bias_line;
                    mc_latch   <= mc_line;
                end
                if (cfg_cnt == 4'd3) begin
                    r_cur <= {C_X_BITS{1'b0}};  c_cur <= 7'd0;
                    pre_mode <= 1'b1;  ld_sub <= 1'b0;
                    bytes_fed <= {C_X_BITS{1'b0}};  beat_full <= 1'b0;
                    kyi <= 2'd0;  kwi <= 2'd0;  cini <= 7'd0;
                    st <= S_LD;
                end
            end

            S_LD: begin
                if (ld_sub == 1'b0) begin
                    rd_req <= 1'b1;
                    rd_req_addr <= rd_base_l + ((c_cur * h_l + r_cur) * w_l);
                    rd_req_len <= w_l;
                    bytes_fed <= {C_X_BITS{1'b0}};
                    beat_full <= 1'b0;
                    ld_sub <= 1'b1;
                end else begin
                    if (!beat_full && rd_valid && rd_ready) begin
                        beat_r <= rd_data;
                        beat_full <= 1'b1;
                    end
                    if (lb_ld_valid && lb_ld_ready) begin
                        bytes_fed <= bytes_fed + 1'b1;
                        if (bytes_fed[3:0] == 4'd15)
                            beat_full <= 1'b0;
                    end
                    if (lb_ld_done) begin
                        if (c_cur == in_ch_l - 1'b1) begin
                            c_cur <= 7'd0;
                            ldbank_cnt <= (ldbank_cnt == 2'd2) ? 2'd0 : ldbank_cnt + 2'd1;
                            if (pre_mode) begin
                                if (r_cur == {C_X_BITS{1'b0}} + 1'b1) begin
                                    pre_mode <= 1'b0;
                                    o_cur <= {C_X_BITS{1'b0}};
                                    x_cur <= {C_X_BITS{1'b0}};
                                    ph <= 13'd0;
                                    st <= S_PIX;
                                end else begin
                                    r_cur <= r_cur + 1'b1;
                                    ld_sub <= 1'b0;
                                end
                            end else begin
                                o_cur <= o_cur + 1'b1;
                                x_cur <= {C_X_BITS{1'b0}};
                                ph <= 13'd0;
                                st <= S_PIX;
                            end
                        end else begin
                            c_cur <= c_cur + 1'b1;
                            ld_sub <= 1'b0;
                        end
                    end
                end
            end

            S_PIX: begin
                if (ph_scan) begin
                    if (cini == in_ch_l - 1'b1) begin
                        cini <= 7'd0;
                        if (kwi == 2'd2) begin
                            kwi <= 2'd0;
                            kyi <= kyi + 1'b1;
                        end else kwi <= kwi + 1'b1;
                    end else cini <= cini + 1'b1;
                end
                rq_v <= ph_rd;
                if (ph_rd)
                    rq_c <= c_read_c;
                if (ph == ph_max) begin
                    ph <= 13'd0;
                    kyi <= 2'd0;  kwi <= 2'd0;  cini <= 7'd0;
                    if (x_cur == w_l - 1'b1) begin
                        x_cur <= {C_X_BITS{1'b0}};
                        seg_c <= {C_X_BITS{1'b0}};
                        byte_i <= {C_X_BITS{1'b0}};
                        pcnt <= 4'd0;
                        seg_start <= 1'b1;
                        wr_valid <= 1'b0;
                        st <= S_ROWWR;
                    end else begin
                        x_cur <= x_cur + 1'b1;
                    end
                end else begin
                    ph <= ph + 1'b1;
                end
            end

            S_ROWWR: begin
                if (seg_start) begin
                    wr_req <= 1'b1;
                    wr_req_addr <= wr_base_l + (seg_c * hp_l) + (o_cur * w_l);
                    wr_req_len <= w_l;
                    seg_start <= 1'b0;
                end
                if (!wr_valid) begin
                    if (byte_i < w_l) begin
                        pack_r[{pcnt, 3'b0} +: 8] <=
                            rowbuf[rb_rd_idx + {{(C_X_BITS-7){1'b0}}, seg_c}];
                        byte_i <= byte_i + 1'b1;
                        if (pcnt == 4'd15) begin
                            wr_data <= {rowbuf[rb_rd_idx +
                                              {{(C_X_BITS-7){1'b0}}, seg_c}], pack_r[119:0]};
                            wr_valid <= 1'b1;
                            pcnt <= 4'd0;
                        end else pcnt <= pcnt + 1'b1;
                    end else begin
                        if (seg_c == out_ch_l - 1'b1) begin
                            bank0_cnt <= (bank0_cnt == 2'd2) ? 2'd0 : bank0_cnt + 2'd1;
                            if (o_cur + 10'd1 == h_l) begin
                                st <= S_DONE;
                            end else if ({1'b0, o_cur} + 11'd2 < {1'b0, h_l}) begin
                                r_cur <= o_cur + 10'd2;
                                c_cur <= 7'd0;
                                ld_sub <= 1'b0;
                                bytes_fed <= {C_X_BITS{1'b0}};
                                beat_full <= 1'b0;
                                st <= S_LD;
                            end else begin
                                o_cur <= o_cur + 1'b1;
                                x_cur <= {C_X_BITS{1'b0}};
                                ph <= 13'd0;
                                st <= S_PIX;
                            end
                        end else begin
                            seg_c <= seg_c + 1'b1;
                            byte_i <= {C_X_BITS{1'b0}};
                            pcnt <= 4'd0;
                            seg_start <= 1'b1;
                        end
                    end
                end else if (wr_ready) begin
                    wr_valid <= 1'b0;
                end
            end

            S_DONE: begin
                done_o <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    assign rd_ready = (st == S_LD) && (ld_sub == 1'b1) && !beat_full;
    assign busy_o = (st != S_IDLE);
    assign w_bank = bank_id_l;
    assign dbg_x = x_cur;
    assign dbg_y = o_cur;

endmodule
