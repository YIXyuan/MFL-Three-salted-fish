`timescale 1ns / 1ps

module kosmo2_ctrl_fsm_v1_0 (
    input  wire             aclk,
    input  wire             rst_n,

    input  wire             start,
    input  wire             abort,
    input  wire [3:0]       layer_beg,
    input  wire [3:0]       layer_end,
    input  wire             dbg_raw,
    input  wire             dbg_skip_relu,
    input  wire             dbg_skip_pool,
    input  wire [31:0]      in_addr,
    input  wire [31:0]      out_addr,
    input  wire [31:0]      rebuf_a,
    input  wire [31:0]      rebuf_b,
    output wire             busy_o,
    output reg              done_o,
    output reg              err_o,
    output wire [3:0]       cur_layer,
    output wire [31:0]      cyc_cnt,
    output wire [3:0]       dbg_state,

    output wire [31:0]      rd_cmd_addr,
    output wire [23:0]      rd_cmd_len,
    output wire             rd_cmd_valid,
    input  wire             rd_cmd_ready,
    input  wire [127:0]     rd_data,
    input  wire             rd_valid,
    input  wire             rd_last,
    output wire             rd_ready,
    input  wire             rd_busy,

    output wire [31:0]      wr_cmd_addr,
    output wire [23:0]      wr_cmd_len,
    output wire             wr_cmd_valid,
    input  wire             wr_cmd_ready,
    output wire [127:0]     wr_data,
    output wire             wr_valid,
    output wire             wr_last,
    input  wire             wr_ready,
    input  wire             wr_busy
);

    localparam [3:0] S_IDLE      = 4'd0,
                     S_CFG       = 4'd1,
                     S_M6        = 4'd2,
                     S_DRAIN_M6  = 4'd3,
                     S_BNDCFG    = 4'd4,
                     S_BNDSTART  = 4'd5,
                     S_BNDRUN    = 4'd6,
                     S_DRAIN_BND = 4'd7,
                     S_NEXT      = 4'd8,
                     S_DONE      = 4'd9,
                     S_ABORT     = 4'd10;

    reg  [3:0]   k, end_l, beg_l;
    wire [127:0] lc;
    kosmo2_layer_cfg_rom_v1_0 u_cfg (
        .layer(k),
        .cfg  (lc)
    );

    wire [6:0]  lc_ic     = lc[6:0];
    wire [6:0]  lc_oc     = lc[13:7];
    wire [10:0] lc_h      = lc[24:14];
    wire [10:0] lc_w      = lc[35:25];
    wire [3:0]  lc_bank   = lc[39:36];
    wire        lc_relu   = lc[40];
    wire        lc_pool   = lc[41];
    wire        lc_bnd    = lc[42];
    wire [4:0]  lc_fsb    = lc[47:43];
    wire [31:0] lc_mcb    = lc[79:48];
    wire [1:0]  lc_in_sel = lc[81:80];
    wire [1:0]  lc_out_sel= lc[83:82];
    wire [1:0]  lc_bout_sel=lc[85:84];

    reg [31:0] in_addr_l, out_addr_l;

    function [31:0] sel_buf;
        input [1:0]  s;
        input [31:0] va, vb, vin, vout;
        begin
            case (s)
                2'd0:    sel_buf = va;
                2'd1:    sel_buf = vb;
                2'd2:    sel_buf = vin;
                default: sel_buf = vout;
            endcase
        end
    endfunction

    wire is_end       = (k == end_l);
    wire [31:0] in_base  = sel_buf(lc_in_sel, rebuf_a, rebuf_b, in_addr_l, out_addr_l);
    wire [31:0] out_base = sel_buf(lc_out_sel, rebuf_a, rebuf_b, in_addr_l, out_addr_l);
    wire [31:0] bnd_in_base  = out_base;
    wire [31:0] bnd_out_base = is_end ? out_addr_l :
                               sel_buf(lc_bout_sel, rebuf_a, rebuf_b, in_addr_l, out_addr_l);

    wire dbg_export   = dbg_skip_relu | dbg_skip_pool;
    wire is_end_dbg   = is_end & dbg_raw;
    wire is_end_exp   = is_end & dbg_export;

    wire bnd_pool_eff = is_end_exp ? (lc_pool & ~dbg_skip_pool) :
                        is_end_dbg ? 1'b0 : lc_pool;
    wire bnd_bnd_eff  = (is_end_dbg || is_end_exp) ? 1'b0 : lc_bnd;
    wire bnd_relu_eff = is_end_exp ? ~dbg_skip_relu : 1'b1;
    wire [31:0] bnd_mc_eff = bnd_bnd_eff ? lc_mcb : 32'h0100_0000;
    wire [4:0]  bnd_fs_eff = bnd_bnd_eff ? lc_fsb : 5'd24;
    wire need_bnd = is_end ? 1'b1 : (lc_pool | lc_bnd);

    wire m6_relu_eff = lc_relu & ~(is_end_exp & dbg_skip_relu);

    reg         m6_cfg_load;
    wire        m6_busy, m6_done;
    wire [3:0]  m6_w_bank;
    wire [9:0]  m6_w_colidx;
    wire [2047:0] w_col;
    wire [8191:0] bias_line, mc_line;
    wire        m6_rd_req;
    wire [31:0] m6_rd_addr;
    wire [10:0] m6_rd_len;
    wire        m6_rd_ready;
    wire        m6_rd_valid;
    wire        m6_wr_req;
    wire [31:0] m6_wr_addr;
    wire [10:0] m6_wr_len;
    wire [127:0] m6_wr_data;
    wire        m6_wr_valid;
    wire        m6_wr_ready;

    kosmo2_pe_layer_v1_0 #(
        .C_CH_MAX(96), .C_X_BITS(11), .C_ROW_BYTES(16384)
    ) u_pe (
        .aclk(aclk), .rst_n(rst_n),
        .cfg_in_ch(lc_ic), .cfg_out_ch(lc_oc),
        .cfg_w(lc_w), .cfg_h(lc_h),
        .cfg_bank_id(lc_bank), .cfg_relu_en(m6_relu_eff),
        .cfg_rd_base(in_base), .cfg_wr_base(out_base),
        .cfg_load(m6_cfg_load),
        .w_bank(m6_w_bank), .w_col_idx(m6_w_colidx), .w_col(w_col),
        .bias_line(bias_line), .mc_line(mc_line),
        .rd_req(m6_rd_req), .rd_req_addr(m6_rd_addr), .rd_req_len(m6_rd_len),
        .rd_data(rd_data), .rd_valid(m6_rd_valid), .rd_ready(m6_rd_ready),
        .wr_req(m6_wr_req), .wr_req_addr(m6_wr_addr), .wr_req_len(m6_wr_len),
        .wr_data(m6_wr_data), .wr_valid(m6_wr_valid), .wr_ready(m6_wr_ready),
        .busy_o(m6_busy), .done_o(m6_done),
        .dbg_state(), .dbg_x(), .dbg_y()
    );

    kosmo2_wram_bank_v1_0 u_wram (
        .aclk(aclk), .rst_n(rst_n),
        .w_bank(m6_w_bank), .w_col_idx(m6_w_colidx),
        .w_col(w_col), .bias_line(bias_line), .mc_line(mc_line)
    );

    reg         bnd_cfg_load, bnd_start;
    wire        bnd_busy, bnd_done;
    wire [31:0] bnd_rd_cmd_addr;
    wire [23:0] bnd_rd_cmd_len;
    wire        bnd_rd_cmd_valid, bnd_rd_ready;
    wire [31:0] bnd_wr_cmd_addr;
    wire [23:0] bnd_wr_cmd_len;
    wire        bnd_wr_cmd_valid;
    wire [127:0] bnd_wr_data;
    wire        bnd_wr_valid, bnd_wr_last, bnd_wr_ready;

    kosmo2_boundary_v1_0 u_bnd (
        .aclk(aclk), .rst_n(rst_n),
        .cfg_load(bnd_cfg_load),
        .cfg_in_base(bnd_in_base), .cfg_out_base(bnd_out_base),
        .cfg_h(lc_h), .cfg_w(lc_w), .cfg_c(lc_oc),
        .cfg_pool(bnd_pool_eff), .cfg_bnd(bnd_bnd_eff),
        .cfg_relu(bnd_relu_eff),
        .cfg_mc(bnd_mc_eff), .cfg_fshift(bnd_fs_eff),
        .start(bnd_start),
        .rd_cmd_addr(bnd_rd_cmd_addr), .rd_cmd_len(bnd_rd_cmd_len),
        .rd_cmd_valid(bnd_rd_cmd_valid), .rd_cmd_ready(rd_cmd_ready),
        .rd_data(rd_data), .rd_valid(bnd_rd_valid), .rd_last(rd_last),
        .rd_ready(bnd_rd_ready),
        .wr_cmd_addr(bnd_wr_cmd_addr), .wr_cmd_len(bnd_wr_cmd_len),
        .wr_cmd_valid(bnd_wr_cmd_valid), .wr_cmd_ready(wr_cmd_ready),
        .wr_data(bnd_wr_data), .wr_valid(bnd_wr_valid), .wr_last(bnd_wr_last),
        .wr_ready(bnd_wr_ready),
        .busy(bnd_busy), .done(bnd_done), .dbg_state()
    );

    reg [3:0] st;
    wire owner_bnd = (st == S_BNDCFG) || (st == S_BNDSTART) ||
                     (st == S_BNDRUN) || (st == S_DRAIN_BND);

    reg        m6_rd_pend, m6_wr_pend;
    reg [31:0] m6_rd_addr_q, m6_wr_addr_q;
    reg [23:0] m6_rd_len_q,  m6_wr_len_q;

    wire m6_rd_issue = m6_rd_req | m6_rd_pend;
    wire m6_wr_issue = m6_wr_req | m6_wr_pend;
    wire m6_rd_accept = m6_rd_issue && !owner_bnd && rd_cmd_ready;
    wire m6_wr_accept = m6_wr_issue && !owner_bnd && wr_cmd_ready;

    always @(posedge aclk) begin
        if (!rst_n) begin
            m6_rd_pend <= 1'b0;  m6_wr_pend <= 1'b0;
            m6_rd_addr_q <= 32'd0;  m6_wr_addr_q <= 32'd0;
            m6_rd_len_q <= 24'd0;   m6_wr_len_q <= 24'd0;
        end else begin
            if (m6_rd_req && !m6_rd_pend && !m6_rd_accept) begin
                m6_rd_pend   <= 1'b1;
                m6_rd_addr_q <= m6_rd_addr;
                m6_rd_len_q  <= {13'd0, m6_rd_len};
            end else if (m6_rd_pend && m6_rd_accept)
                m6_rd_pend <= 1'b0;

            if (m6_wr_req && !m6_wr_pend && !m6_wr_accept) begin
                m6_wr_pend   <= 1'b1;
                m6_wr_addr_q <= m6_wr_addr;
                m6_wr_len_q  <= {13'd0, m6_wr_len};
            end else if (m6_wr_pend && m6_wr_accept)
                m6_wr_pend <= 1'b0;
        end
    end

    wire [31:0] m6_rd_addr_e = m6_rd_pend ? m6_rd_addr_q : m6_rd_addr;
    wire [23:0] m6_rd_len_e  = m6_rd_pend ? m6_rd_len_q  : {13'd0, m6_rd_len};
    wire [31:0] m6_wr_addr_e = m6_wr_pend ? m6_wr_addr_q : m6_wr_addr;
    wire [23:0] m6_wr_len_e  = m6_wr_pend ? m6_wr_len_q  : {13'd0, m6_wr_len};

    assign rd_cmd_valid = owner_bnd ? bnd_rd_cmd_valid : m6_rd_issue;
    assign rd_cmd_addr  = owner_bnd ? bnd_rd_cmd_addr  : m6_rd_addr_e;
    assign rd_cmd_len   = owner_bnd ? bnd_rd_cmd_len   : m6_rd_len_e;
    assign rd_ready     = owner_bnd ? bnd_rd_ready     : m6_rd_ready;
    assign m6_rd_valid  = rd_valid && !owner_bnd;
    assign bnd_rd_valid = rd_valid &&  owner_bnd;

    assign wr_cmd_valid = owner_bnd ? bnd_wr_cmd_valid : m6_wr_issue;
    assign wr_cmd_addr  = owner_bnd ? bnd_wr_cmd_addr  : m6_wr_addr_e;
    assign wr_cmd_len   = owner_bnd ? bnd_wr_cmd_len   : m6_wr_len_e;
    assign wr_data      = owner_bnd ? bnd_wr_data      : m6_wr_data;
    assign wr_valid     = owner_bnd ? bnd_wr_valid     : m6_wr_valid;
    assign wr_last      = owner_bnd ? bnd_wr_last      : 1'b0;
    assign m6_wr_ready  = owner_bnd ? 1'b0             : wr_ready;
    assign bnd_wr_ready = owner_bnd ? wr_ready         : 1'b0;

    reg        busy_r;
    reg        abort_pending;
    reg [31:0] cyc;

    assign dbg_state = st;
    assign busy_o    = busy_r;
    assign cur_layer = k;
    assign cyc_cnt   = cyc;

    always @(posedge aclk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            k <= 4'd0;  beg_l <= 4'd0;  end_l <= 4'd0;
            busy_r <= 1'b0;  done_o <= 1'b0;  err_o <= 1'b0;
            abort_pending <= 1'b0;
            m6_cfg_load <= 1'b0;  bnd_cfg_load <= 1'b0;  bnd_start <= 1'b0;
            in_addr_l <= 32'd0;   out_addr_l <= 32'd0;
            cyc <= 32'd0;
        end else begin
            done_o <= 1'b0;

            if (busy_r)
                cyc <= cyc + 32'd1;

            case (st)

            S_IDLE: begin
                m6_cfg_load  <= 1'b0;
                bnd_cfg_load <= 1'b0;
                bnd_start    <= 1'b0;
                if (start) begin
                    in_addr_l <= in_addr;
                    out_addr_l <= out_addr;
                    beg_l <= layer_beg;
                    end_l <= layer_end;
                    k     <= layer_beg;
                    cyc   <= 32'd0;
                    err_o <= 1'b0;
                    abort_pending <= 1'b0;
                    if ((layer_beg > layer_end) || (layer_end > 4'd9)) begin
                        err_o  <= 1'b1;
                        busy_r <= 1'b0;
                        st     <= S_IDLE;
                    end else begin
                        busy_r <= 1'b1;
                        st     <= S_CFG;
                    end
                end
            end

            S_CFG: begin
                if (abort) begin
                    abort_pending <= 1'b1;
                    st <= S_ABORT;
                end else begin
                    m6_cfg_load <= 1'b1;
                    st <= S_M6;
                end
            end

            S_M6: begin
                m6_cfg_load <= 1'b0;
                if (m6_done) begin
                    if (abort) abort_pending <= 1'b1;
                    st <= S_DRAIN_M6;
                end
            end
            S_DRAIN_M6: begin
                if (!rd_busy && !wr_busy) begin
                    if (abort_pending)       st <= S_ABORT;
                    else if (need_bnd)       st <= S_BNDCFG;
                    else                     st <= S_NEXT;
                end
            end

            S_BNDCFG: begin
                bnd_cfg_load <= 1'b1;
                st <= S_BNDSTART;
            end
            S_BNDSTART: begin
                bnd_cfg_load <= 1'b0;
                bnd_start    <= 1'b1;
                st <= S_BNDRUN;
            end
            S_BNDRUN: begin
                bnd_start <= 1'b0;
                if (bnd_done) begin
                    if (abort) abort_pending <= 1'b1;
                    st <= S_DRAIN_BND;
                end
            end
            S_DRAIN_BND: begin
                if (!rd_busy && !wr_busy) begin
                    if (abort_pending)       st <= S_ABORT;
                    else if (k == end_l)     st <= S_DONE;
                    else                     st <= S_NEXT;
                end
            end

            S_NEXT: begin
                if (abort) begin
                    abort_pending <= 1'b1;
                    st <= S_ABORT;
                end else begin
                    k  <= k + 4'd1;
                    st <= S_CFG;
                end
            end

            S_DONE: begin
                done_o <= 1'b1;
                busy_r <= 1'b0;
                st     <= S_IDLE;
            end
            S_ABORT: begin
                err_o  <= 1'b1;
                busy_r <= 1'b0;
                st     <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
