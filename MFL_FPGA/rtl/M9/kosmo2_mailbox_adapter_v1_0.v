`timescale 1ns / 1ps

module kosmo2_mailbox_adapter_v1_0 #(
    parameter [31:0]  C_MBOX_BASE      = 32'h0030_1000,
    parameter [31:0]  C_VERSION        = 32'h2026_1018,
    parameter integer C_POLL_CYC       = 150000,
    parameter integer C_DRAIN_CYC      = 75000000,
    parameter integer C_DONE_HOLD_CYC  = 75000000,
    parameter integer C_RST_CYC        = 16,
    parameter integer C_BOOT_WAIT      = 32,
    parameter integer C_REL_WAIT       = 32,

    parameter integer C_EXT_WORDS      = 0
)(
    input  wire        aclk,
    input  wire        rst_n,

    output reg         mb_cmd_op,
    output reg  [31:0] mb_cmd_addr,
    output reg  [127:0] mb_cmd_wdata,
    output reg  [15:0] mb_cmd_wstrb,
    output reg         mb_cmd_valid,
    input  wire        mb_cmd_ready,
    input  wire        mb_rsp_valid,
    input  wire [127:0] mb_rsp_rdata,
    input  wire        mb_rsp_err,
    input  wire        mb_busy,

    output reg         m8_start,
    output reg  [31:0] m8_in_addr,
    output reg  [31:0] m8_out_addr,
    output reg  [3:0]  m8_layer_end,
    output reg         m8_dbg_skip_relu,
    output reg         m8_dbg_skip_pool,
    output reg         m8_abort,
    input  wire        m8_busy,
    input  wire        m8_done,
    input  wire        m8_err,

    input  wire        rd_busy,
    input  wire        wr_busy,

    output wire        rst_n_core,

    output wire [5:0]  dbg_state,
    output wire [31:0] dbg_status
);

    localparam [31:0] MB = C_MBOX_BASE;

    localparam [5:0] S_BOOT       = 6'd0,
                     S_BOOT_VW    = 6'd1,
                     S_BOOT_VWW   = 6'd2,
                     S_BOOT_SW    = 6'd3,
                     S_BOOT_SWW   = 6'd4,
                     S_POLL_WAIT  = 6'd5,
                     S_POLL_R0    = 6'd6,
                     S_POLL_W0    = 6'd7,
                     S_POLL_R1    = 6'd8,
                     S_POLL_W1    = 6'd9,
                     S_GHOST_IS   = 6'd10,
                     S_GHOST_W    = 6'd11,
                     S_START_CW   = 6'd12,
                     S_START_CWW  = 6'd13,
                     S_START_SW   = 6'd14,
                     S_START_SWW  = 6'd15,
                     S_RUN_WAIT   = 6'd16,
                     S_RUN_R0     = 6'd17,
                     S_RUN_W0     = 6'd18,
                     S_RUN_R1     = 6'd19,
                     S_RUN_W1     = 6'd20,
                     S_RUN_CHK    = 6'd21,
                     S_RUN_SW     = 6'd22,
                     S_RUN_SWW    = 6'd23,
                     S_RST_CI     = 6'd24,
                     S_RST_CW     = 6'd25,
                     S_RST_DRAIN  = 6'd26,
                     S_RST_ASSERT = 6'd27,
                     S_RST_HOLD   = 6'd28,
                     S_RST_REL    = 6'd29,
                     S_RST_SW     = 6'd30,
                     S_RST_SWW    = 6'd31,
                     S_RST_CW2    = 6'd32,
                     S_RST_RW     = 6'd33,
                     S_RST_RWW    = 6'd34,
                     S_CMD_WAIT   = 6'd35,
                     S_WAIT_EN    = 6'd40,
                     S_WAIT_EN_W  = 6'd41,
                     S_RUN_PC     = 6'd42,
                     S_DONE_HOLD  = 6'd43,
                     S_PEND_START = 6'd44;

    reg [5:0] st;
    assign dbg_state = st;

    reg         cmd_go, cmd_flush;
    reg         cmd_op_r;
    reg [31:0]  cmd_addr_r;
    reg [127:0] cmd_wdata_r;
    reg [15:0]  cmd_wstrb_r;
    reg [5:0]   cmd_next;

    reg         cmd_busy;
    reg         cmd_done;
    reg         cmd_err;
    reg [127:0] cmd_rdata;

    reg         core_rst_active;

    wire seq_rst_n = rst_n & ~core_rst_active & ~cmd_flush;

    always @(posedge aclk) begin
        if (!seq_rst_n) begin
            mb_cmd_op    <= 1'b0;
            mb_cmd_addr  <= 32'd0;
            mb_cmd_wdata <= 128'd0;
            mb_cmd_wstrb <= 16'd0;
            mb_cmd_valid <= 1'b0;
            cmd_busy     <= 1'b0;
            cmd_done     <= 1'b0;
            cmd_err      <= 1'b0;
            cmd_rdata    <= 128'd0;
        end else begin
            cmd_done <= 1'b0;
            if (!cmd_busy) begin
                mb_cmd_valid <= 1'b0;
                if (cmd_go) begin
                    mb_cmd_op    <= cmd_op_r;
                    mb_cmd_addr  <= cmd_addr_r;
                    mb_cmd_wdata <= cmd_wdata_r;
                    mb_cmd_wstrb <= cmd_wstrb_r;
                    mb_cmd_valid <= 1'b1;
                    cmd_busy     <= 1'b1;
                end
            end else begin
                if (mb_cmd_valid && mb_cmd_ready)
                    mb_cmd_valid <= 1'b0;
                if (mb_rsp_valid) begin
                    cmd_done  <= 1'b1;
                    cmd_err   <= mb_rsp_err;
                    cmd_rdata <= mb_rsp_rdata;
                    cmd_busy  <= 1'b0;
                end
            end
        end
    end

    task issue_read;
        input [31:0] a;
        input [5:0]  nxt;
        begin
            cmd_op_r    <= 1'b0;
            cmd_addr_r  <= a;
            cmd_wdata_r <= 128'd0;
            cmd_wstrb_r <= 16'd0;
            cmd_go      <= 1'b1;
            cmd_next    <= nxt;
            st          <= S_CMD_WAIT;
        end
    endtask

    task issue_write;
        input [31:0]  a;
        input [127:0] d;
        input [15:0]  s;
        input [5:0]   nxt;
        begin
            cmd_op_r    <= 1'b1;
            cmd_addr_r  <= a;
            cmd_wdata_r <= d;
            cmd_wstrb_r <= s;
            cmd_go      <= 1'b1;
            cmd_next    <= nxt;
            st          <= S_CMD_WAIT;
        end
    endtask

    reg        last_err;
    reg [127:0] last_data;
    reg [31:0] layer_word;
    reg        boot_ok;
    reg        version_done;

    reg        frame_active;
    reg        ghost_err;
    reg        axi_err;
    reg        done_seen;
    reg        frame_err;
    reg        clean;

    reg [17:0] poll_cnt;
    reg [26:0] drain_cnt;
    reg [26:0] hold_cnt;
    reg [4:0]  rst_cnt;
    reg [4:0]  rel_cnt;
    reg [5:0]  boot_cnt;

    reg [31:0] status_last;

    reg [31:0] poll_in, poll_out;
    reg        poll_ctrl;
    reg [31:0] run_in, run_out;
    reg        run_ctrl;

    reg        pend_valid;
    reg [31:0] pend_in, pend_out;
    reg [3:0]  pend_layer_end;
    reg        pend_skr, pend_skp;

    assign rst_n_core = rst_n & ~core_rst_active;
    assign dbg_status = status_last;

    wire tick = (poll_cnt == (C_POLL_CYC - 1));

    function [3:0] f_end;
        input [31:0] lw;
        reg [7:0] lraw;
        reg [3:0] lraw4;
        begin
            lraw  = lw[7:0];
            lraw4 = lraw[3:0];
            if (lraw == 8'hFF)       f_end = 4'd9;
            else if (lraw <= 8'd9)   f_end = lraw[3:0];
            else if (lraw4 <= 4'd9)  f_end = lraw4;
            else                     f_end = 4'd9;
        end
    endfunction

    wire [3:0] d_end = f_end(layer_word);
    wire       d_skr = layer_word[8];
    wire       d_skp = layer_word[9];

    wire last_in_ok  = ((last_data[31:0] >= 32'h0030_2000) &&
                        (last_data[31:0] <  32'h0046_A000)) ||
                       ((last_data[31:0] >= 32'h0150_0000) &&
                        (last_data[31:0] <  32'h0170_0000));
    wire last_out_ok = ((last_data[63:32] >= 32'h0047_0000) &&
                        (last_data[63:32] <  32'h0047_B400)) ||
                       ((last_data[63:32] >= 32'h0050_0000) &&
                        (last_data[63:32] <  32'h0150_0000));
    wire boot_addr_ok = last_in_ok && last_out_ok;

    wire poll_in_ok  = ((poll_in >= 32'h0030_2000) && (poll_in < 32'h0046_A000)) ||
                       ((poll_in >= 32'h0150_0000) && (poll_in < 32'h0170_0000));
    wire poll_out_ok = ((poll_out >= 32'h0047_0000) && (poll_out < 32'h0047_B400)) ||
                       ((poll_out >= 32'h0050_0000) && (poll_out < 32'h0150_0000));
    wire start_addr_ok = poll_in_ok && poll_out_ok;

    wire run_in_ok  = ((run_in >= 32'h0030_2000) && (run_in < 32'h0046_A000)) ||
                      ((run_in >= 32'h0150_0000) && (run_in < 32'h0170_0000));
    wire run_out_ok = ((run_out >= 32'h0047_0000) && (run_out < 32'h0047_B400)) ||
                      ((run_out >= 32'h0050_0000) && (run_out < 32'h0150_0000));
    wire run_addr_ok = run_in_ok && run_out_ok;

    wire [31:0] sts = (frame_err | ghost_err | axi_err) ? 32'h6 : 32'h2;

    always @(posedge aclk) begin
        if (!rst_n) begin
            st <= S_WAIT_EN;

            cmd_go <= 1'b0; cmd_flush <= 1'b0;
            cmd_op_r <= 1'b0; cmd_addr_r <= 32'd0; cmd_wdata_r <= 128'd0;
            cmd_wstrb_r <= 16'd0; cmd_next <= S_WAIT_EN;
            last_err <= 1'b0; last_data <= 128'd0; layer_word <= 32'd0;
            boot_ok <= 1'b0; version_done <= 1'b0;
            m8_start <= 1'b0; m8_in_addr <= 32'd0; m8_out_addr <= 32'd0;
            m8_layer_end <= 4'd9; m8_dbg_skip_relu <= 1'b0; m8_dbg_skip_pool <= 1'b0;
            m8_abort <= 1'b0;
            frame_active <= 1'b0; ghost_err <= 1'b0; axi_err <= 1'b0;
            done_seen <= 1'b0; frame_err <= 1'b0; clean <= 1'b1;
            poll_cnt <= 18'd0; drain_cnt <= 27'd0; hold_cnt <= 27'd0;
            rst_cnt <= 5'd0; rel_cnt <= 5'd0; boot_cnt <= 6'd0;
            core_rst_active <= 1'b0; status_last <= 32'd0;
            poll_in <= 32'd0; poll_out <= 32'd0; poll_ctrl <= 1'b0;
            run_in <= 32'd0; run_out <= 32'd0; run_ctrl <= 1'b0;
            pend_valid <= 1'b0; pend_in <= 32'd0; pend_out <= 32'd0;
            pend_layer_end <= 4'd9; pend_skr <= 1'b0; pend_skp <= 1'b0;
        end else begin
            m8_start  <= 1'b0;
            cmd_go    <= 1'b0;
            cmd_flush <= 1'b0;

            if (tick) poll_cnt <= 18'd0;
            else      poll_cnt <= poll_cnt + 18'd1;

            if (m8_done) begin
                done_seen <= 1'b1;
                frame_err <= m8_err;
            end

            case (st)

            S_WAIT_EN: begin
                if (tick)
                    issue_read(MB + 32'h0, S_WAIT_EN_W);
            end
            S_WAIT_EN_W: begin
                if (last_err)
                    st <= S_WAIT_EN;
                else if (boot_addr_ok) begin
                    boot_ok <= 1'b1;
                    st <= S_BOOT;
                end else
                    st <= S_WAIT_EN;
            end

            S_BOOT: begin
                if (boot_cnt >= (C_BOOT_WAIT - 1)) begin
                    if (!version_done && (C_EXT_WORDS != 0)) st <= S_BOOT_VW;
                    else                                    st <= S_BOOT_SW;
                end else
                    boot_cnt <= boot_cnt + 6'd1;
            end
            S_BOOT_VW:  issue_write(MB + 32'h10, {32'd0, C_VERSION, 64'd0},
                                    16'h0F00, S_BOOT_VWW);
            S_BOOT_VWW: begin
                if (last_err) begin
                    boot_cnt <= 6'd0;
                    st <= S_BOOT;
                end else begin
                    version_done <= 1'b1;
                    st <= S_BOOT_SW;
                end
            end
            S_BOOT_SW:  issue_write(MB + 32'h10, {96'd0, 32'h0}, 16'h000F, S_BOOT_SWW);
            S_BOOT_SWW: begin
                if (last_err) begin
                    boot_cnt <= 6'd0;
                    st <= S_BOOT;
                end else begin
                    status_last <= 32'h0;
                    st <= S_POLL_WAIT;
                end
            end

            S_POLL_WAIT: if (tick) st <= S_POLL_R0;
            S_POLL_R0:   issue_read(MB + 32'h0, S_POLL_W0);
            S_POLL_W0: begin
                if (last_err)
                    st <= S_POLL_WAIT;
                else begin
                    poll_in   <= last_data[31:0];
                    poll_out  <= last_data[63:32];
                    poll_ctrl <= last_data[96];
                    st <= S_POLL_R1;
                end
            end
            S_POLL_R1:   issue_read(MB + 32'h10, S_POLL_W1);
            S_POLL_W1: begin
                if (last_err)
                    st <= S_POLL_WAIT;
                else if ((C_EXT_WORDS != 0) && (last_data[127:96] == 32'h0000_0001))
                    st <= S_RST_CI;
                else begin
                    layer_word <= last_data[63:32];
                    if (boot_ok && poll_ctrl && start_addr_ok) begin
                        if (frame_active || m8_busy) begin
                            ghost_err <= 1'b1;
                            st <= S_GHOST_IS;
                        end else begin
                            m8_in_addr  <= poll_in;
                            m8_out_addr <= poll_out;
                            st <= S_START_CW;
                        end
                    end else
                        st <= S_POLL_WAIT;
                end
            end
            S_GHOST_IS: issue_write(MB + 32'h0, 128'd0, 16'hF000, S_GHOST_W);
            S_GHOST_W:  st <= S_POLL_WAIT;

            S_START_CW:  issue_write(MB + 32'h0, 128'd0, 16'hF000, S_START_CWW);
            S_START_CWW: issue_write(MB + 32'h10, {96'd0, 32'h1}, 16'h000F, S_START_SW);
            S_START_SW: begin
                status_last <= 32'h1;
                m8_start <= 1'b1;
                m8_layer_end    <= d_end;
                m8_dbg_skip_relu<= d_skr;
                m8_dbg_skip_pool<= d_skp;
                frame_active <= 1'b1;
                ghost_err <= 1'b0;
                axi_err   <= 1'b0;
                done_seen <= 1'b0;
                frame_err <= 1'b0;
                st <= S_START_SWW;
            end
            S_START_SWW: st <= S_RUN_WAIT;

            S_RUN_WAIT: if (tick) st <= S_RUN_R0;
            S_RUN_R0:   issue_read(MB + 32'h0, S_RUN_W0);
            S_RUN_W0: begin
                if (last_err)
                    axi_err <= 1'b1;
                else begin
                    run_in   <= last_data[31:0];
                    run_out  <= last_data[63:32];
                    run_ctrl <= last_data[96];
                    st <= S_RUN_R1;
                end
            end
            S_RUN_R1:   issue_read(MB + 32'h10, S_RUN_W1);
            S_RUN_W1: begin
                if (last_err)
                    axi_err <= 1'b1;
                else if ((C_EXT_WORDS != 0) && (last_data[127:96] == 32'h0000_0001))
                    st <= S_RST_CI;
                else begin
                    layer_word <= last_data[63:32];
                    if (run_ctrl) begin
                        if (pend_valid) begin
                            ghost_err <= 1'b1;
                            st <= S_RUN_PC;
                        end else if (run_addr_ok) begin
                            pend_in        <= run_in;
                            pend_out       <= run_out;
                            pend_layer_end <= f_end(last_data[63:32]);
                            pend_skr       <= last_data[40];
                            pend_skp       <= last_data[41];
                            pend_valid     <= 1'b1;
                            st <= S_RUN_PC;
                        end else
                            st <= S_RUN_PC;
                    end else
                        st <= S_RUN_CHK;
                end
            end
            S_RUN_PC: issue_write(MB + 32'h0, 128'd0, 16'hF000, S_RUN_CHK);
            S_RUN_CHK: begin
                if (done_seen) st <= S_RUN_SW;
                else           st <= S_RUN_WAIT;
            end
            S_RUN_SW:  issue_write(MB + 32'h10, {96'd0, sts}, 16'h000F, S_RUN_SWW);
            S_RUN_SWW: begin
                if (last_err)
                    st <= S_RUN_SW;
                else begin
                    status_last <= sts;
                    frame_active <= 1'b0;
                    if (pend_valid) begin
                        hold_cnt <= 27'd0;
                        st <= S_DONE_HOLD;
                    end else
                        st <= S_POLL_WAIT;
                end
            end

            S_DONE_HOLD: begin
                if (hold_cnt >= (C_DONE_HOLD_CYC - 1))
                    st <= S_PEND_START;
                else
                    hold_cnt <= hold_cnt + 27'd1;
            end
            S_PEND_START: begin
                m8_in_addr  <= pend_in;
                m8_out_addr <= pend_out;
                m8_layer_end    <= pend_layer_end;
                m8_dbg_skip_relu<= pend_skr;
                m8_dbg_skip_pool<= pend_skp;
                m8_start <= 1'b1;
                frame_active <= 1'b1;
                status_last  <= 32'h1;
                pend_valid   <= 1'b0;
                ghost_err    <= 1'b0;
                axi_err      <= 1'b0;
                done_seen    <= 1'b0;
                frame_err    <= 1'b0;
                issue_write(MB + 32'h10, {96'd0, 32'h1}, 16'h000F, S_RUN_WAIT);
            end

            S_RST_CI: begin
                m8_abort <= 1'b1;
                pend_valid <= 1'b0;
                issue_write(MB + 32'h0, 128'd0, 16'hF000, S_RST_CW);
            end
            S_RST_CW: begin
                drain_cnt <= 27'd0;
                st <= S_RST_DRAIN;
            end
            S_RST_DRAIN: begin
                if (!m8_busy && !rd_busy && !wr_busy && !mb_busy) begin
                    clean <= 1'b1;
                    st <= S_RST_ASSERT;
                end else if (drain_cnt >= (C_DRAIN_CYC - 1)) begin
                    clean <= 1'b0;
                    st <= S_RST_ASSERT;
                end else
                    drain_cnt <= drain_cnt + 27'd1;
            end
            S_RST_ASSERT: begin
                cmd_flush <= 1'b1;
                core_rst_active <= 1'b1;
                rst_cnt <= 5'd0;
                pend_valid <= 1'b0;
                st <= S_RST_HOLD;
            end
            S_RST_HOLD: begin
                if (rst_cnt >= (C_RST_CYC - 1)) begin
                    core_rst_active <= 1'b0;
                    rel_cnt <= 5'd0;
                    st <= S_RST_REL;
                end else
                    rst_cnt <= rst_cnt + 5'd1;
            end
            S_RST_REL: begin
                if (rel_cnt >= (C_REL_WAIT - 1)) st <= S_RST_SW;
                else rel_cnt <= rel_cnt + 5'd1;
            end
            S_RST_SW:  issue_write(MB + 32'h10, {96'd0, (clean ? 32'h0 : 32'h6)},
                                   16'h000F, S_RST_SWW);
            S_RST_SWW: begin
                if (last_err)
                    st <= S_RST_SW;
                else begin
                    status_last <= clean ? 32'h0 : 32'h6;
                    st <= S_RST_CW2;
                end
            end
            S_RST_CW2: issue_write(MB + 32'h0, 128'd0, 16'hF000, S_RST_RW);
            S_RST_RW:  issue_write(MB + 32'h10, 128'd0, 16'hF000, S_RST_RWW);
            S_RST_RWW: begin
                if (last_err)
                    st <= S_RST_RW;
                else begin
                    m8_abort <= 1'b0;
                    frame_active <= 1'b0;
                    pend_valid <= 1'b0;
                    if (clean) begin
                        boot_ok <= 1'b0;
                        boot_cnt <= 6'd0;
                        st <= S_WAIT_EN;
                    end else
                        st <= S_POLL_WAIT;
                end
            end

            S_CMD_WAIT: begin
                if (cmd_done) begin
                    last_err  <= cmd_err;
                    last_data <= cmd_rdata;
                    st <= cmd_next;
                end
            end
            default: st <= S_WAIT_EN;
            endcase
        end
    end

endmodule
