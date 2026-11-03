// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_m9_top_v1_0.v
// Description : kosmo2_m9_top_v1_0 自校验 TB（M9 集成）
//
//   环境:
//   * PU_SPS0 行为模型（C_MEM_D=21 -> 32MB，覆盖 scratch B 末址 0x1480000）
//   * ARM 侧通过层次任务直接改 DDR 邮箱/IN_BUF（模拟 ARM 写共享内存）
//   * M8 用缩放测试配置覆盖 ROM（32x512 起，5 次池化 -> 1x16）
//
//   T0 VERSION: 适配器首次邮箱读成功后写 0x301018=0x20261018，STATUS=0
//   T1 邮箱单层: LAYER=0x300|0 -> 清 CTRL/写 STATUS=1/启动 M8；
//      done 后 STATUS=0x2；OUT 与 pre-ReLU conv00 金模型逐字节一致；
//      同时验证 WSTRB 只改目标字（LAYER/IN/OUT 不变）
//   T2 忙中 ghost start: BUSY 中再写 CTRL=1 -> 当前帧完成 STATUS=0x6，CTRL 清 0
//   T3 空闲软复位: RESET=1 -> 自清 0, STATUS=0，VERSION/IN/OUT/LAYER 保留
//   T4 忙中软复位: BUSY 时 RESET=1 -> 排空(M8 abort 层边界) -> STATUS=0, RESET=0
//
//   运行: python tools/run_sim.py --ip ip/kosmo2_m9_top
//           --with ip/kosmo2_ctrl_fsm --with ip/kosmo2_pe_layer
//           --with ip/kosmo2_line_buffer --with ip/kosmo2_mac_array
//           --with ip/kosmo2_requant --with ip/kosmo2_wram_bank
//           --with ../Kosmo2_IP/Kosmo2_IP/ip/kosmo2_pu_ddr_bridge
//           --do sim_m9_top.do
//   Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_m9_top_v1_0;

    localparam [31:0] MBOX    = 32'h0030_1000;
    localparam [31:0] IN_BUF  = 32'h0030_2000;
    localparam [31:0] OUT_BUF = 32'h0047_0000;
    localparam integer N_IN   = 49152;       // 3*32*512
    localparam integer N_C0   = 262144;      // 16*32*512
    localparam [31:0] VERSION_EXP = 32'h2026_1018;
    localparam [31:0] OUT_B2      = 32'h00D0_0000;   // scratch B
    localparam [127:0] MBOX_SENTINEL =
        128'hA5A5_5A5A_A5A5_5A5A_A5A5_5A5A_A5A5_5A5A;

    reg aclk;
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- DUT ----------------
    wire        sps0_awvalid, sps0_awready;
    wire [3:0]  sps0_awid;
    wire [31:0] sps0_awaddr;
    wire [7:0]  sps0_awlen;
    wire [2:0]  sps0_awsize;
    wire [1:0]  sps0_awburst;
    wire        sps0_awlock;
    wire [3:0]  sps0_awcache;
    wire [2:0]  sps0_awprot;
    wire [3:0]  sps0_awqos;
    wire        sps0_wvalid, sps0_wready;
    wire [127:0] sps0_wdata;
    wire [15:0] sps0_wstrb;
    wire        sps0_wlast;
    wire        sps0_bvalid, sps0_bready;
    wire [3:0]  sps0_bid;
    wire [1:0]  sps0_bresp;
    wire        sps0_arvalid, sps0_arready;
    wire [3:0]  sps0_arid;
    wire [31:0] sps0_araddr;
    wire [7:0]  sps0_arlen;
    wire [2:0]  sps0_arsize;
    wire [1:0]  sps0_arburst;
    wire        sps0_arlock;
    wire [3:0]  sps0_arcache;
    wire [2:0]  sps0_arprot;
    wire [3:0]  sps0_arqos;
    wire        sps0_rvalid, sps0_rready;
    wire [3:0]  sps0_rid;
    wire [127:0] sps0_rdata;
    wire [1:0]  sps0_rresp;
    wire        sps0_rlast;

    wire        o_m8_busy, o_m8_done, o_m8_err;
    wire [31:0] o_mbox_status;
    wire [5:0]  o_adapter_state;
    wire        o_mbox_busy;
    wire        o_bist_busy, o_bist_done, o_bist_pass;

    wire        sps_resetn;

    kosmo2_m9_top_v1_0 #(
        .C_EXT_WORDS_EN(1),         // TB 验证 VERSION/RESET 扩展字
        .C_DONE_HOLD_CYC(5000000)   // 50ms @100MHz，T2 可见 hold
    ) u_m9 (
        .i_aclk         (aclk),
        .i_sps0_resetn  (sps_resetn),
        .o_sps0_clk     (),
        .sps0_awvalid   (sps0_awvalid),
        .sps0_awready   (sps0_awready),
        .sps0_awid      (sps0_awid),
        .sps0_awaddr    (sps0_awaddr),
        .sps0_awlen     (sps0_awlen),
        .sps0_awsize    (sps0_awsize),
        .sps0_awburst   (sps0_awburst),
        .sps0_awlock    (sps0_awlock),
        .sps0_awcache   (sps0_awcache),
        .sps0_awprot    (sps0_awprot),
        .sps0_awqos     (sps0_awqos),
        .sps0_wvalid    (sps0_wvalid),
        .sps0_wready    (sps0_wready),
        .sps0_wdata     (sps0_wdata),
        .sps0_wstrb     (sps0_wstrb),
        .sps0_wlast     (sps0_wlast),
        .sps0_bvalid    (sps0_bvalid),
        .sps0_bid       (sps0_bid),
        .sps0_bresp     (sps0_bresp),
        .sps0_bready    (sps0_bready),
        .sps0_arvalid   (sps0_arvalid),
        .sps0_arready   (sps0_arready),
        .sps0_arid      (sps0_arid),
        .sps0_araddr    (sps0_araddr),
        .sps0_arlen     (sps0_arlen),
        .sps0_arsize    (sps0_arsize),
        .sps0_arburst   (sps0_arburst),
        .sps0_arlock    (sps0_arlock),
        .sps0_arcache   (sps0_arcache),
        .sps0_arprot    (sps0_arprot),
        .sps0_arqos     (sps0_arqos),
        .sps0_rvalid    (sps0_rvalid),
        .sps0_rid       (sps0_rid),
        .sps0_rdata     (sps0_rdata),
        .sps0_rresp     (sps0_rresp),
        .sps0_rlast     (sps0_rlast),
        .sps0_rready    (sps0_rready),
        .o_m8_busy      (o_m8_busy),
        .o_m8_done      (o_m8_done),
        .o_m8_err       (o_m8_err),
        .o_mbox_status  (o_mbox_status),
        .o_adapter_state(o_adapter_state),
        .o_mbox_busy    (o_mbox_busy),
        .o_bist_busy    (o_bist_busy),
        .o_bist_done    (o_bist_done),
        .o_bist_pass    (o_bist_pass)
    );

    // ---------------- SPS/DDR 行为模型（32MB 窗口） ----------------
    kosmo2_pu_sps_model_v1_0 #(
        .C_DW(128), .C_IDW(4), .C_MEM_D(21), .C_SEED(32'h1234_5678)
    ) u_sps (
        .aclk    (aclk),
        .resetn  (sps_resetn),
        .awvalid (sps0_awvalid), .awready(sps0_awready), .awid(sps0_awid),
        .awaddr  (sps0_awaddr),  .awlen  (sps0_awlen),
        .wvalid  (sps0_wvalid),  .wready (sps0_wready),
        .wdata   (sps0_wdata),   .wstrb  (sps0_wstrb), .wlast(sps0_wlast),
        .bvalid  (sps0_bvalid),  .bready (sps0_bready),
        .bid     (sps0_bid),     .bresp  (sps0_bresp),
        .arvalid (sps0_arvalid), .arready(sps0_arready), .arid(sps0_arid),
        .araddr  (sps0_araddr),  .arlen  (sps0_arlen),
        .rvalid  (sps0_rvalid),  .rready (sps0_rready), .rid(sps0_rid),
        .rdata   (sps0_rdata),   .rresp  (sps0_rresp), .rlast(sps0_rlast)
    );

    // ---------------- 向量/期望 ----------------
    reg [7:0]   inbytes [0:N_IN-1];
    reg [7:0]   exp0pre [0:N_C0-1];
    reg [127:0] tcfg [0:9];

    integer err_cnt;
    integer i, j, k;

    reg [16:0] dbg_div;
    reg        dbg_on;

    always @(posedge aclk) begin
        if (dbg_on && u_m9.u_mux.d_ar_fire)
            $display("[F] t=%0t D_AR addr=%08h len=%0d", $time, u_m9.d_araddr, u_m9.d_arlen);
        if (dbg_on && u_m9.u_mux.m_ar_fire)
            $display("[F] t=%0t M_AR addr=%08h len=%0d", $time, u_m9.mb_araddr, u_m9.mb_arlen);
        if (dbg_on && u_m9.u_mux.r_fire_last)
            $display("[F] t=%0t R_LAST", $time);
        if (dbg_on && u_m9.u_mux.d_aw_fire)
            $display("[F] t=%0t D_AW addr=%08h", $time, u_m9.d_awaddr);
        if (dbg_on && u_m9.u_mux.b_fire)
            $display("[F] t=%0t B_FIRE", $time);
        if (dbg_on && u_m9.rd_busy)
            ;
    end

    // ---------------- 100us 监视（调试邮箱/AXI 链路） ----------------
    always @(posedge aclk) begin
        dbg_div <= dbg_div + 17'd1;
        if (dbg_on && dbg_div == 17'd9999) begin
            dbg_div <= 17'd0;
            $display("[M] t=%0t ad=%0d sel=%0d | m8st=%0d k=%0d pest=%0d o=%0d x=%0d ph=%0d | pe_wrreq=%0d pe_wrv=%0d pe_wrrdy=%0d seg_st=%0d byte_i=%0d seg_c=%0d | m8wcv=%0d m8wcr=%0d m8wrdy=%0d wrst=%0d",
                     $time,
                     u_m9.u_adapter.st, u_m9.u_mux.sel,
                     u_m9.u_m8.st, u_m9.u_m8.k,
                     u_m9.u_m8.u_pe.st, u_m9.u_m8.u_pe.o_cur,
                     u_m9.u_m8.u_pe.x_cur, u_m9.u_m8.u_pe.ph,
                     u_m9.u_m8.u_pe.wr_req, u_m9.u_m8.u_pe.wr_valid,
                     u_m9.u_m8.u_pe.wr_ready, u_m9.u_m8.u_pe.seg_start,
                     u_m9.u_m8.u_pe.byte_i, u_m9.u_m8.u_pe.seg_c,
                     u_m9.m8_wr_cmd_valid, u_m9.m8_wr_cmd_ready,
                     u_m9.m8_wr_ready, u_m9.u_dma_wr.state);
        end
    end

    // ---------------- ARM 侧邮箱访问（直接改 DDR 模型） ----------------
    task mb_peek;
        input  [31:0] off;
        output [31:0] data;
        reg [31:0]  a;
        reg [127:0] b;
        begin
            a = MBOX + (off & 32'hFFFF_FFF0);
            u_sps.peek_beat(a, b);
            case (off[3:2])
                2'd0:    data = b[31:0];
                2'd1:    data = b[63:32];
                2'd2:    data = b[95:64];
                default: data = b[127:96];
            endcase
        end
    endtask

    task mb_poke;
        input [31:0] off;
        input [31:0] data;
        reg [31:0]  a;
        reg [127:0] b;
        begin
            a = MBOX + (off & 32'hFFFF_FFF0);
            u_sps.peek_beat(a, b);
            case (off[3:2])
                2'd0:    b[31:0]    = data;
                2'd1:    b[63:32]   = data;
                2'd2:    b[95:64]   = data;
                default: b[127:96]  = data;
            endcase
            u_sps.poke_beat(a, b);
        end
    endtask

    task wait_status;
        input  [31:0] want;
        input  integer max_polls;      // 100us/次
        output integer ok;
        integer n;
        reg [31:0] s;
        begin
            ok = 0;
            for (n = 0; n < max_polls; n = n + 1) begin
                mb_peek(32'h10, s);
                if (s === want) begin
                    ok = 1;
                    n  = max_polls;
                end else
                    #100_000;          // 100 us
            end
        end
    endtask

    task wait_reset0;
        input  integer max_polls;
        output integer ok;
        integer n;
        reg [31:0] s;
        begin
            ok = 0;
            for (n = 0; n < max_polls; n = n + 1) begin
                mb_peek(32'h1C, s);
                if (s === 32'h0) begin
                    ok = 1;
                    n  = max_polls;
                end else
                    #100_000;
            end
        end
    endtask

    task check_out_pre_at;
        input [31:0] base;
        input integer n;
        input [8*16-1:0] tag;
        integer m, q, nerr;
        reg [127:0] b;
        begin
            nerr = 0;
            for (m = 0; m < n; m = m + 16) begin
                u_sps.peek_beat(base + m, b);
                for (q = 0; q < 16; q = q + 1)
                    if (b[q*8 +: 8] !== exp0pre[m+q]) begin
                        if (nerr < 8)
                            $display("[FAIL] %0s byte %0d got=%02h exp=%02h",
                                     tag, m+q, b[q*8 +: 8], exp0pre[m+q]);
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

    task check_out_pre;
        input integer n;
        input [8*16-1:0] tag;
        begin
            check_out_pre_at(OUT_BUF, n, tag);
        end
    endtask

    // ---------------- LAYER 解码观测（rev3） ----------------
    task check_layer;
        input [31:0] val;
        input [3:0]  eend;
        input        eskr, eskp;
        reg [3:0] gend;
        reg gskr, gskp;
        begin
            mb_poke(32'h14, val);
            #4_000_000;                    // 等 2+ 个 1.5ms 轮询
            gend = u_m9.u_adapter.d_end;
            gskr = u_m9.u_adapter.d_skr;
            gskp = u_m9.u_adapter.d_skp;
            if (gend !== eend || gskr !== eskr || gskp !== eskp) begin
                $display("[FAIL] T5 LAYER=%08h got end=%0d skr=%0d skp=%0d exp %0d/%0d/%0d",
                         val, gend, gskr, gskp, eend, eskr, eskp);
                err_cnt = err_cnt + 1;
            end else
                $display("[ ok ] T5 LAYER=%08h -> end=%0d skr=%0d skp=%0d",
                         val, gend, gskr, gskp);
        end
    endtask

    // ---------------- 主测试序列 ----------------
    integer ok;
    reg [31:0] s, v;
    reg [127:0] b;

    initial begin
        err_cnt = 0;
        dbg_div = 17'd0;
        dbg_on  = 1'b0;

        // 预置 u-boot 残留哨兵：boot magic 之前适配器不得写邮箱（只允许读）
        for (i = 0; i < 4; i = i + 1)
            u_sps.poke_beat(MBOX + i*16, MBOX_SENTINEL);

        // 缩放测试配置 + 输入 + 期望
        $readmemh("../vec/layer_cfg_test.hex", tcfg);
        #1;
        for (i = 0; i < 10; i = i + 1) u_m9.u_m8.u_cfg.rom[i] = tcfg[i];

        $readmemh("../vec/m8_in.hex", inbytes);
        for (i = 0; i < N_IN; i = i + 16) begin
            b = 128'd0;
            for (j = 0; j < 16; j = j + 1) b[j*8 +: 8] = inbytes[i+j];
            u_sps.poke_beat(IN_BUF + i, b);
        end
        $readmemh("../vec/m8_conv00_prerelu_exp.hex", exp0pre);

        $timeformat(-9, 0, " ns", 12);
        // 等 SPS 模型释放复位；适配器此时在 S_WAIT_EN，只读不写
        #5_000_000;

        // ---- T00: 有效 IN/OUT 之前邮箱一字未写 ----
        u_sps.peek_beat(MBOX, b);
        if (b !== MBOX_SENTINEL) begin
            $display("[FAIL] T00 block0 changed before valid IN/OUT: %h", b);
            err_cnt = err_cnt + 1;
        end
        u_sps.peek_beat(MBOX + 16, b);
        if (b !== MBOX_SENTINEL) begin
            $display("[FAIL] T00 block1 changed before valid IN/OUT: %h", b);
            err_cnt = err_cnt + 1;
        end
        if (err_cnt == 0)
            $display("[ ok ] T00 no mailbox write before valid IN/OUT");

        // ARM 写有效 IN/OUT（无需 magic/CTRL=0），触发 boot
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h0C, 32'h0);
        #5_000_000;   // 覆盖 1ms 轮询 + VERSION/STATUS 写

        // ---- T0: VERSION ----
        $display("=== T0: VERSION 0x301018 ===");
        ok = 0;
        for (i = 0; i < 1000; i = i + 1) begin
            mb_peek(32'h18, v);
            if (v === VERSION_EXP) begin ok = 1; i = 1000; end
            else #100_000;
        end
        if (!ok) begin
            $display("[FAIL] T0 VERSION read=%08h exp=%08h", v, VERSION_EXP);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T0 VERSION=%08h", v);
        mb_peek(32'h10, s);
        if (s !== 32'h0) begin
            $display("[FAIL] T0 STATUS=%08h exp=0", s);
            err_cnt = err_cnt + 1;
        end

        // ---- T1: 邮箱单层 pre-ReLU 导出 ----
        $display("=== T1: mailbox single-layer pre-ReLU export ===");
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h14, 32'h0000_0300);      // LAYER=0x300|0
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h1, 3000, ok);
        if (!ok) begin
            $display("[FAIL] T1 no BUSY (STATUS=%08h, adapter st=%0d)", s, o_adapter_state);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T1 BUSY observed");
        wait_status(32'h2, 8000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T1 no DONE (STATUS=%08h, adapter st=%0d, m8 busy=%0d)",
                     s, o_adapter_state, o_m8_busy);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T1 STATUS=0x2");
        mb_peek(32'h0C, s);
        if (s !== 32'h0) begin
            $display("[FAIL] T1 CTRL not cleared: %08h", s);
            err_cnt = err_cnt + 1;
        end
        mb_peek(32'h14, s);
        if (s !== 32'h0000_0300) begin
            $display("[FAIL] T1 LAYER corrupted: %08h", s);
            err_cnt = err_cnt + 1;
        end
        mb_peek(32'h00, s);
        if (s !== IN_BUF) begin
            $display("[FAIL] T1 IN_ADDR corrupted: %08h", s);
            err_cnt = err_cnt + 1;
        end
        mb_peek(32'h04, s);
        if (s !== OUT_BUF) begin
            $display("[FAIL] T1 OUT_ADDR corrupted: %08h", s);
            err_cnt = err_cnt + 1;
        end
        check_out_pre(N_C0, "T1_out");

        // ---- T2: 双帧 pending（A 运行中 submit B） ----
        $display("=== T2: two-frame pending queue ===");
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h14, 32'h0000_0300);
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h1, 3000, ok);
        if (!ok) begin
            $display("[FAIL] T2 A no BUSY");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2 A BUSY");
        // B 在 A BUSY 中提交：进入 pending，不判 ghost
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_B2);
        mb_poke(32'h14, 32'h0000_0300);
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h2, 8000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T2 A no DONE (STATUS=%08h)", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2 A DONE");
        check_out_pre_at(OUT_BUF, N_C0, "T2_A");
        // A DONE 后 hold：STATUS 应保持 2，B 还没启动
        #1_000_000;
        mb_peek(32'h10, s);
        if (s !== 32'h2) begin
            $display("[FAIL] T2 hold STATUS=%08h exp=0x2", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2 hold STATUS=0x2");
        // hold 结束后 B 启动
        wait_status(32'h1, 2000, ok);
        if (!ok) begin
            $display("[FAIL] T2 B no BUSY");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2 B BUSY");
        wait_status(32'h2, 8000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T2 B no DONE (STATUS=%08h)", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2 B DONE");
        check_out_pre_at(OUT_B2, N_C0, "T2_B");
        check_out_pre_at(OUT_BUF, N_C0, "T2_A_after");

        // ---- T2b: pending 溢出 -> 当前帧 0x6 ----
        $display("=== T2b: pending overflow ===");
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h14, 32'h0000_0300);
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h1, 3000, ok);
        if (!ok) begin
            $display("[FAIL] T2b A no BUSY");
            err_cnt = err_cnt + 1;
        end
        // B -> pending
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_B2);
        mb_poke(32'h14, 32'h0000_0300);
        mb_poke(32'h0C, 32'h1);
        // 等 CTRL 清 0，确认 B 已被锁进 pending
        ok = 0;
        for (i = 0; i < 1000; i = i + 1) begin
            mb_peek(32'h0C, s);
            if (s === 32'h0) begin ok = 1; i = 1000; end
            else #100_000;
        end
        if (!ok) begin
            $display("[FAIL] T2b B not accepted into pending");
            err_cnt = err_cnt + 1;
        end
        // C -> pending 满，触发 ghost/0x6
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_B2);
        mb_poke(32'h14, 32'h0000_0300);
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h6, 10000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T2b STATUS=%08h exp=0x6", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T2b overflow -> STATUS=0x6");
        // 等 B pending 完成，回到 idle 供 T3 使用
        wait_status(32'h1, 3000, ok);
        wait_status(32'h2, 8000, ok);

        // ---- T3: 空闲软复位 ----
        $display("=== T3: idle soft reset ===");
        mb_poke(32'h1C, 32'h1);
        wait_reset0(2000, ok);               // 200 ms
        if (!ok) begin
            $display("[FAIL] T3 RESET not cleared");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T3 RESET self-cleared");
        wait_status(32'h0, 2000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T3 STATUS=%08h exp=0", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T3 STATUS=0x0");
        mb_peek(32'h18, v);
        if (v !== VERSION_EXP) begin
            $display("[FAIL] T3 VERSION lost: %08h", v);
            err_cnt = err_cnt + 1;
        end
        mb_peek(32'h14, s);
        if (s !== 32'h0000_0300) begin
            $display("[FAIL] T3 LAYER lost: %08h", s);
            err_cnt = err_cnt + 1;
        end

        // ---- T4: 忙中软复位（排空成功） ----
        $display("=== T4: busy soft reset (drain) ===");
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h1, 3000, ok);
        if (!ok) begin
            $display("[FAIL] T4 no BUSY");
            err_cnt = err_cnt + 1;
        end
        mb_poke(32'h1C, 32'h1);
        #2_000_000;                          // 让适配器检测 RESET 并进入排空
        mb_poke(32'h0C, 32'h1);              // 复位期间违规写 START（应被末段 CTRL=0 清掉）
        wait_reset0(5000, ok);               // 500 ms
        if (!ok) begin
            $display("[FAIL] T4 RESET not cleared");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T4 RESET self-cleared");
        wait_status(32'h0, 2000, ok);
        if (!ok) begin
            mb_peek(32'h10, s);
            $display("[FAIL] T4 STATUS=%08h exp=0", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T4 STATUS=0x0 (drained)");
        mb_peek(32'h0C, s);
        if (s !== 32'h0) begin
            $display("[FAIL] T4 CTRL not cleared: %08h", s);
            err_cnt = err_cnt + 1;
        end
        mb_peek(32'h18, v);
        if (v !== VERSION_EXP) begin
            $display("[FAIL] T4 VERSION lost: %08h", v);
            err_cnt = err_cnt + 1;
        end

        // ---- T5: LAYER 解码（v3.2 rev3 口径）----
        $display("=== T5: LAYER decode (rev3) ===");
        check_layer(32'h0000_0010, 4'd0, 1'b0, 1'b0);   // N>=0x10 低4位 -> L0
        check_layer(32'h0000_0011, 4'd1, 1'b0, 1'b0);   // -> L1
        check_layer(32'h0000_001F, 4'd9, 1'b0, 1'b0);   // 0xF > 9 -> L9
        check_layer(32'h0000_000A, 4'd9, 1'b0, 1'b0);   // 0x0A -> L9
        check_layer(32'h0000_02FF, 4'd9, 1'b0, 1'b1);   // 全链 + 跳池化
        check_layer(32'h0000_01FF, 4'd9, 1'b1, 1'b0);   // 全链 + 跳 ReLU
        check_layer(32'h0000_0300, 4'd0, 1'b1, 1'b1);   // 0x300|0
        check_layer(32'h0000_0309, 4'd9, 1'b1, 1'b1);   // 0x300|9

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #2_000_000_000;
        $display("TB FAIL (timeout) adapter=%0d m8busy=%0d mboxbusy=%0d status=%08h",
                 o_adapter_state, o_m8_busy, o_mbox_busy, o_mbox_status);
        $finish;
    end

endmodule
