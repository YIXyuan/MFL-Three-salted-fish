// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_ctrl_fsm_v1_0.v
// Description : kosmo2_ctrl_fsm_v1_0 自校验 testbench（M8）
//
//   环境:
//   * DDR 行为模型（紧凑地址重映射, 覆盖 IN/A/B/OUT 四区）
//   * M2 DMA 行为服务器（严格 cmd_valid/ready + 16B 流 + last + busy）
//   * DUT 内部 M6/M7/边界引擎全部为真实 RTL
//
//   T1 单层导出: layer_beg=end=0, dbg_raw=1 -> conv00 原始 post-ReLU 输出
//      (16x32x512 = 262,144 B) 写到 OUT_BUF, 与金模型逐字节比对
//   T2 全链:     layer_beg=0, end=9 -> 10 层 conv + 5 次池化 + McB 换挡,
//      最终 96x1x16 = 1,536 B 逐字节比对（缩放链路, 真实权重/Mc/McB）
//   T3 abort:    layer 0 运行中拉 abort -> 层边界回 IDLE, err=1, busy=0
//
//   向量/配置由 tools/gen_m8_cfg.py 生成（禁止手抄）
//   运行: python tools/run_sim.py --ip ip/kosmo2_ctrl_fsm
//           --with ip/kosmo2_pe_layer --with ip/kosmo2_line_buffer
//           --with ip/kosmo2_mac_array --with ip/kosmo2_requant
//           --with ip/kosmo2_wram_bank --do sim_ctrl_fsm.do
//   Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ctrl_fsm_v1_0;

    // 紧凑地址重映射（RTL 地址算术是 32bit, 数值本身无关; 图省仿真内存）
    localparam [31:0]  IN_BASE  = 32'h0001_0000;
    localparam [31:0]  A_BASE   = 32'h0002_0000;
    localparam [31:0]  B_BASE   = 32'h0006_0000;
    localparam [31:0]  OUT_BASE = 32'h000A_0000;
    localparam integer DDR_BYTES = 917504;      // 0xE0000

    localparam integer N_IN   = 49152;          // 3*32*512
    localparam integer N_C0   = 262144;         // 16*32*512
    localparam integer N_L1B  = 65536;          // 16*16*256（层 1 边界处理后）
    localparam integer N_FIN  = 1536;           // 96*1*16
    localparam integer DBG_T1_ONLY = 0;         // 调试开关: 1=只跑 T1

    reg         aclk, rst_n;
    reg         start, abort, dbg_raw, dbg_skip_relu, dbg_skip_pool;
    reg  [3:0]  layer_beg, layer_end;
    reg  [31:0] in_addr, out_addr, rebuf_a, rebuf_b;

    wire        busy_o, done_o, err_o;
    wire [3:0]  cur_layer;
    wire [31:0] cyc_cnt;
    wire [3:0]  dbg_state;

    wire [31:0] rd_cmd_addr;
    wire [23:0] rd_cmd_len;
    wire        rd_cmd_valid;
    wire        rd_cmd_ready;
    wire [127:0] rd_data;
    wire        rd_valid, rd_last;
    wire        rd_ready;
    wire        rd_busy;

    wire [31:0] wr_cmd_addr;
    wire [23:0] wr_cmd_len;
    wire        wr_cmd_valid;
    wire        wr_cmd_ready;
    wire [127:0] wr_data;
    wire        wr_valid, wr_last;
    wire        wr_ready;
    wire        wr_busy;

    // ---------------- DUT ----------------
    kosmo2_ctrl_fsm_v1_0 u_dut (
        .aclk(aclk), .rst_n(rst_n),
        .start(start), .abort(abort),
        .layer_beg(layer_beg), .layer_end(layer_end), .dbg_raw(dbg_raw),
        .dbg_skip_relu(dbg_skip_relu), .dbg_skip_pool(dbg_skip_pool),
        .in_addr(in_addr), .out_addr(out_addr),
        .rebuf_a(rebuf_a), .rebuf_b(rebuf_b),
        .busy_o(busy_o), .done_o(done_o), .err_o(err_o),
        .cur_layer(cur_layer), .cyc_cnt(cyc_cnt), .dbg_state(dbg_state),
        .rd_cmd_addr(rd_cmd_addr), .rd_cmd_len(rd_cmd_len),
        .rd_cmd_valid(rd_cmd_valid), .rd_cmd_ready(rd_cmd_ready),
        .rd_data(rd_data), .rd_valid(rd_valid), .rd_last(rd_last),
        .rd_ready(rd_ready), .rd_busy(rd_busy),
        .wr_cmd_addr(wr_cmd_addr), .wr_cmd_len(wr_cmd_len),
        .wr_cmd_valid(wr_cmd_valid), .wr_cmd_ready(wr_cmd_ready),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_last(wr_last),
        .wr_ready(wr_ready), .wr_busy(wr_busy)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- 存储模型 ----------------
    reg [7:0]   ddr [0:DDR_BYTES-1];
    reg [7:0]   inbytes [0:N_IN-1];
    reg [7:0]   exp0 [0:N_C0-1];
    reg [7:0]   exp0pre [0:N_C0-1];
    reg [7:0]   exp1pre [0:N_C0-1];
    reg [7:0]   expl1b [0:N_L1B-1];
    reg [7:0]   expf [0:N_FIN-1];
    reg [127:0] tcfg [0:9];

    integer err_cnt;
    integer i;

    function [127:0] beat_at;
        input [31:0] a;
        begin
            beat_at = {ddr[a+15], ddr[a+14], ddr[a+13], ddr[a+12],
                       ddr[a+11], ddr[a+10], ddr[a+9],  ddr[a+8],
                       ddr[a+7],  ddr[a+6],  ddr[a+5],  ddr[a+4],
                       ddr[a+3],  ddr[a+2],  ddr[a+1],  ddr[a]};
        end
    endfunction

    // ---------------- M2 读服务器 ----------------
    reg [31:0]  rs_addr;
    reg [15:0]  rs_beats;
    reg         rs_busy, rs_valid;
    reg [127:0] rs_data;

    wire rs_last        = (rs_beats == 16'd1);
    wire rs_cmd_ready   = !rs_busy;
    assign rd_cmd_ready = rs_cmd_ready;
    assign rd_data      = rs_data;
    assign rd_valid     = rs_valid;
    assign rd_last      = rs_last;
    assign rd_busy      = rs_busy;

    always @(posedge aclk) begin
        if (!rst_n) begin
            rs_addr <= 32'd0;  rs_beats <= 16'd0;
            rs_busy <= 1'b0;   rs_valid <= 1'b0;  rs_data <= 128'd0;
        end else begin
            if (rd_cmd_valid && rs_cmd_ready) begin
                rs_addr  <= rd_cmd_addr;
                rs_beats <= rd_cmd_len[15:4];
                rs_data  <= beat_at(rd_cmd_addr);
                rs_valid <= 1'b1;
                rs_busy  <= 1'b1;
            end
            if (rs_valid && rd_ready) begin
                if (rs_beats <= 16'd1) begin
                    rs_valid <= 1'b0;
                    rs_busy  <= 1'b0;
                    rs_beats <= 16'd0;
                end else begin
                    rs_addr  <= rs_addr + 32'd16;
                    rs_beats <= rs_beats - 16'd1;
                    rs_data  <= beat_at(rs_addr + 32'd16);
                end
            end
        end
    end

    // ---------------- M2 写服务器 ----------------
    reg [31:0]  ws_addr;
    reg [15:0]  ws_beats;
    reg         ws_busy, ws_ready;

    wire ws_cmd_ready   = !ws_busy;
    assign wr_cmd_ready = ws_cmd_ready;
    assign wr_ready     = ws_ready;
    assign wr_busy      = ws_busy;

    always @(posedge aclk) begin
        if (!rst_n) begin
            ws_addr <= 32'd0;  ws_beats <= 16'd0;
            ws_busy <= 1'b0;   ws_ready <= 1'b0;
        end else begin
            if (wr_cmd_valid && ws_cmd_ready) begin
                ws_addr  <= wr_cmd_addr;
                ws_beats <= wr_cmd_len[15:4];
                ws_busy  <= 1'b1;
                ws_ready <= 1'b1;
            end
            if (wr_valid && ws_ready) begin
                ddr[ws_addr+0]  <= wr_data[7:0];
                ddr[ws_addr+1]  <= wr_data[15:8];
                ddr[ws_addr+2]  <= wr_data[23:16];
                ddr[ws_addr+3]  <= wr_data[31:24];
                ddr[ws_addr+4]  <= wr_data[39:32];
                ddr[ws_addr+5]  <= wr_data[47:40];
                ddr[ws_addr+6]  <= wr_data[55:48];
                ddr[ws_addr+7]  <= wr_data[63:56];
                ddr[ws_addr+8]  <= wr_data[71:64];
                ddr[ws_addr+9]  <= wr_data[79:72];
                ddr[ws_addr+10] <= wr_data[87:80];
                ddr[ws_addr+11] <= wr_data[95:88];
                ddr[ws_addr+12] <= wr_data[103:96];
                ddr[ws_addr+13] <= wr_data[111:104];
                ddr[ws_addr+14] <= wr_data[119:112];
                ddr[ws_addr+15] <= wr_data[127:120];
                ws_addr <= ws_addr + 32'd16;
                if (ws_beats <= 16'd1) begin
                    ws_ready <= 1'b0;
                    ws_busy  <= 1'b0;
                    ws_beats <= 16'd0;
                end else begin
                    ws_beats <= ws_beats - 16'd1;
                end
            end
        end
    end

    // ---------------- 任务 ----------------
    task prefill_out;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) ddr[OUT_BASE + k] = 8'h5A;
        end
    endtask

    task run_chain;
        input [3:0] beg, eend;
        input       raw, skr, skp;
        input integer nfill;
        begin
            layer_beg = beg;  layer_end = eend;
            dbg_raw = raw;  dbg_skip_relu = skr;  dbg_skip_pool = skp;
            prefill_out(nfill);
            @(negedge aclk); start = 1'b1;
            @(negedge aclk); start = 1'b0;
            wait (busy_o === 1'b1);
            wait (done_o === 1'b1);
            @(posedge aclk);
            #1;
            if (busy_o !== 1'b0) begin
                $display("[FAIL] busy still high after done");
                err_cnt = err_cnt + 1;
            end
            if (err_o !== 1'b0) begin
                $display("[FAIL] err_o set during normal run (layer_end=%0d)", eend);
                err_cnt = err_cnt + 1;
            end
            if (cur_layer !== eend) begin
                $display("[FAIL] cur_layer=%0d exp=%0d", cur_layer, eend);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    task check_exp;
        input [8*16-1:0] tag;
        input integer n;
        input integer which;      // 0=expf 1=exp0 2=exp0pre 3=exp1pre 4=expl1b
        integer k, nerr;
        reg [7:0] e;
        begin
            nerr = 0;
            for (k = 0; k < n; k = k + 1) begin
                case (which)
                    1:       e = exp0[k];
                    2:       e = exp0pre[k];
                    3:       e = exp1pre[k];
                    4:       e = expl1b[k];
                    default: e = expf[k];
                endcase
                if (ddr[OUT_BASE + k] !== e) begin
                    if (nerr < 8)
                        $display("[FAIL] %0s byte %0d got=%02h exp=%02h",
                                 tag, k, ddr[OUT_BASE + k], e);
                    nerr = nerr + 1;
                end
            end
            if (nerr != 0) begin
                $display("[FAIL] %0s: %0d/%0d bytes mismatched", tag, nerr, n);
                err_cnt = err_cnt + nerr;
            end else
                $display("[ ok ] %0s: %0d bytes all match", tag, n);
        end
    endtask

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt = 0;
        rst_n = 1'b0;
        start = 1'b0;  abort = 1'b0;  dbg_raw = 1'b0;
        dbg_skip_relu = 1'b0;  dbg_skip_pool = 1'b0;
        layer_beg = 4'd0;  layer_end = 4'd9;
        in_addr = IN_BASE;  out_addr = OUT_BASE;
        rebuf_a = A_BASE;   rebuf_b = B_BASE;
        for (i = 0; i < DDR_BYTES; i = i + 1) ddr[i] = 8'h00;
        $timeformat(-9, 0, " ns", 12);

        // 缩放链路测试配置（覆盖 ROM; 真实工程 ROM 是满尺寸 layer_cfg.mem）
        $readmemh("../vec/layer_cfg_test.hex", tcfg);
        #1;
        for (i = 0; i < 10; i = i + 1) u_dut.u_cfg.rom[i] = tcfg[i];

        $readmemh("../vec/m8_in.hex", inbytes);
        for (i = 0; i < N_IN; i = i + 1) ddr[IN_BASE + i] = inbytes[i];
        $readmemh("../vec/m8_conv00_exp.hex", exp0);
        $readmemh("../vec/m8_conv00_prerelu_exp.hex", exp0pre);
        $readmemh("../vec/m8_conv01_prerelu_exp.hex", exp1pre);
        $readmemh("../vec/m8_l1_bnd_exp.hex", expl1b);
        $readmemh("../vec/m8_final_exp.hex", expf);

        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        // ---- T1: 单层 conv00 原始 post-ReLU 输出（M1 dbg_raw 旧语义）----
        $display("=== T1: layer 0 raw export post-ReLU (16x32x512) ===");
        run_chain(4'd0, 4'd0, 1'b1, 1'b0, 1'b0, N_C0);
        check_exp("T1_conv00", N_C0, 1);

        // ---- T1b: `0x300|0` pre-ReLU pre-Pool 导出 ----
        $display("=== T1b: layer 0 pre-ReLU export (16x32x512) ===");
        run_chain(4'd0, 4'd0, 1'b0, 1'b1, 1'b1, N_C0);
        check_exp("T1b_conv00_pre", N_C0, 2);

        // ---- T1c: LAYER=1 正常停层 -> 边界处理后口径（层 2 输入）----
        $display("=== T1c: stop at layer 1, boundary-processed (16x16x256) ===");
        run_chain(4'd0, 4'd1, 1'b0, 1'b0, 1'b0, N_L1B);
        check_exp("T1c_l1_bnd", N_L1B, 4);

        // ---- T1d: `0x300|1` pre-ReLU pre-Pool 导出（层 1 原始 conv）----
        $display("=== T1d: layer 1 pre-ReLU export (16x32x512) ===");
        run_chain(4'd0, 4'd1, 1'b0, 1'b1, 1'b1, N_C0);
        check_exp("T1d_conv01_pre", N_C0, 3);

        if (!DBG_T1_ONLY) begin
        // ---- T2: 10 层全链 ----
        $display("=== T2: full chain 10 layers -> 96x1x16 ===");
        run_chain(4'd0, 4'd9, 1'b0, 1'b0, 1'b0, N_FIN);
        check_exp("T2_final", N_FIN, 0);
        if (cyc_cnt == 32'd0) begin
            $display("[FAIL] cyc_cnt is zero");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] cycles=%0d", cyc_cnt);

        // ---- T3: abort（层边界生效）----
        $display("=== T3: abort during layer 0 ===");
        layer_beg = 4'd0;  layer_end = 4'd9;  dbg_raw = 1'b0;
        dbg_skip_relu = 1'b0;  dbg_skip_pool = 1'b0;
        prefill_out(N_FIN);
        @(negedge aclk); start = 1'b1;
        @(negedge aclk); start = 1'b0;
        wait (busy_o === 1'b1);
        repeat (2000) @(posedge aclk);
        @(negedge aclk); abort = 1'b1;
        wait (busy_o === 1'b0);
        @(posedge aclk); #1;
        if (err_o !== 1'b1) begin
            $display("[FAIL] T3 abort: err_o not set");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T3 abort: err=1, busy=0 (layer boundary)");
        @(negedge aclk); abort = 1'b0;

        // 新 start 应清 err（用单层短跑验证, 避免再跑一遍全链）
        layer_end = 4'd0;  dbg_raw = 1'b1;
        dbg_skip_relu = 1'b0;  dbg_skip_pool = 1'b0;
        @(negedge aclk); start = 1'b1;
        @(negedge aclk); start = 1'b0;
        @(posedge aclk); #1;
        if (err_o !== 1'b0) begin
            $display("[FAIL] T3: err_o not cleared by new start");
            err_cnt = err_cnt + 1;
        end
        wait (done_o === 1'b1);
        @(posedge aclk); #1;
        if (busy_o !== 1'b0) begin
            $display("[FAIL] T3: busy not cleared after restart");
            err_cnt = err_cnt + 1;
        end
        end // !DBG_T1_ONLY

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗（全链缩放图约 15M 拍 = 150ms 仿真时间）
    initial begin
        #500_000_000;
        $display("TB FAIL (timeout) m8st=%0d k=%0d busy=%0d | bnd st=%0d c=%0d y2=%0d pi=%0d qidx=%0d w2=%0d bcnt=%0d rqv=%0d rqvld=%0d rdcv=%0d rdrdy=%0d wrcv=%0d wrrdy=%0d",
                 dbg_state, cur_layer, busy_o,
                 u_dut.u_bnd.st, u_dut.u_bnd.c_cnt, u_dut.u_bnd.y2_cnt,
                 u_dut.u_bnd.pi, u_dut.u_bnd.qidx, u_dut.u_bnd.w2,
                 u_dut.u_bnd.bcnt, u_dut.u_bnd.rq_v, u_dut.u_bnd.rq_q_valid,
                 rd_cmd_valid, rd_ready, wr_cmd_valid, wr_ready);
        $finish;
    end

endmodule
