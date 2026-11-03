// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_m9_full_v1_0.v
// Description : M9 满尺寸 10 层全链长仿真（生产地址 + 真实 480x1024 输入）
//
//   流程:
//   1) 从 vec_full/ 读取 92,160 个 128bit 输入 beat（1,474,560 B）写入 IN_BUF
//   2) 等待适配器 boot，邮箱写 IN/OUT/LAYER=0xFF/CTRL=1
//   3) 轮询 STATUS=0x2；超时或 0x6 判 FAIL
//   4) 从 OUT_BUF 读 2,880 个 beat（46,080 B）与金标准逐字节比对
//
//   规模: 满尺寸 480x1024 起，10 层，5 次池化 -> 96x15x32。
//   运行: python tools/run_sim.py --ip ip/kosmo2_m9_top
//           --with ip/kosmo2_ctrl_fsm --with ip/kosmo2_pe_layer
//           --with ip/kosmo2_line_buffer --with ip/kosmo2_mac_array
//           --with ip/kosmo2_requant --with ip/kosmo2_wram_bank
//           --with ip/kosmo2_axi_dma_rd --with ip/kosmo2_axi_dma_wr
//           --with ../Kosmo2_IP/Kosmo2_IP/ip/kosmo2_pu_ddr_bridge
//           --do sim_m9_full.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_m9_full_v1_0;

    localparam [31:0] MBOX    = 32'h0030_1000;
    localparam [31:0] IN_BUF  = 32'h0030_2000;
    localparam [31:0] OUT_BUF = 32'h0047_0000;
    localparam integer N_IN_BEATS  = 92160;   // 1,474,560 B / 16
    localparam integer N_OUT_BEATS = 2880;    // 46,080 B / 16

    reg aclk;
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;                    // 100 MHz（拍数与 150MHz 相同）

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
        .C_EXT_WORDS_EN(0),                 // 生产默认：不启用 VERSION/RESET
        .C_DONE_HOLD_CYC(5000000)           // 本 TB 单帧；给个非零值
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

    // ---------------- 向量 ----------------
    reg [127:0] in_beats  [0:N_IN_BEATS-1];
    reg [127:0] exp_beats [0:N_OUT_BEATS-1];
    integer err_cnt;
    integer i, m, q, nerr;
    reg [31:0] cyc;
    reg [31:0] s;
    reg [127:0] b;
    integer ok;
    integer cyc_busy, cyc_done;

    always @(posedge aclk) begin
        cyc <= cyc + 32'd1;
        if (cyc != 32'd0 && cyc[23:0] == 24'd0)
            $display("[progress] cyc=%0d t=%0t status=%08h m8busy=%0d",
                     cyc, $time, o_mbox_status, o_m8_busy);
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

    task poll_status;
        input  [31:0] want;
        input  integer max_polls;
        output integer ok;
        output [31:0] got;
        integer n;
        begin
            ok = 0;
            got = 32'h0;
            for (n = 0; n < max_polls; n = n + 1) begin
                mb_peek(32'h10, got);
                if (got === want) begin
                    ok = 1;
                    n  = max_polls;
                end else if (got === 32'h6) begin
                    ok = 0;
                    n  = max_polls;
                end else
                    #100_000;                  // 100 us
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        err_cnt = 0;
        cyc     = 32'd0;
        cyc_busy = 0;
        cyc_done = 0;

        // 邮箱清零 + 有效 IN/OUT（触发 boot，无 magic）
        for (i = 0; i < 3; i = i + 1)
            u_sps.poke_beat(MBOX + i*16, 128'd0);
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h0C, 32'h0);

        // 满尺寸输入 / 金标准输出
        $readmemh("../vec_full/m9_full_in_beats.hex",  in_beats);
        $readmemh("../vec_full/m9_full_exp_beats.hex", exp_beats);
        $display("[info] loading %0d input beats into IN_BUF", N_IN_BEATS);
        for (i = 0; i < N_IN_BEATS; i = i + 1)
            u_sps.poke_beat(IN_BUF + i*16, in_beats[i]);

        $timeformat(-9, 0, " ns", 12);
        #5_000_000;                            // 5 ms: 复位 + 适配器 boot

        $display("=== full-size chain: 480x1024, 10 layers, LAYER=0xFF ===");
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h14, 32'h0000_00FF);
        mb_poke(32'h0C, 32'h0000_0001);

        poll_status(32'h1, 5000, ok, s);
        if (!ok) begin
            $display("[FAIL] no BUSY, STATUS=%08h adapter=%0d m8busy=%0d",
                     s, o_adapter_state, o_m8_busy);
            err_cnt = err_cnt + 1;
        end else begin
            cyc_busy = cyc;
            $display("[ ok ] BUSY observed at cyc=%0d", cyc);
        end

        poll_status(32'h2, 50000, ok, s);      // 5 s simulated
        if (!ok) begin
            $display("[FAIL] no DONE, STATUS=%08h adapter=%0d m8busy=%0d m8err=%0d cyc=%0d",
                     s, o_adapter_state, o_m8_busy, o_m8_err, cyc);
            err_cnt = err_cnt + 1;
        end else begin
            cyc_done = cyc;
            $display("[ ok ] DONE at cyc=%0d (busy cycles=%0d, %.3f ms @100MHz)",
                     cyc, cyc_done - cyc_busy,
                     (cyc_done - cyc_busy) * 10.0 / 1.0e6);
        end

        // 逐字节比对 OUT_BUF
        nerr = 0;
        for (m = 0; m < N_OUT_BEATS; m = m + 1) begin
            u_sps.peek_beat(OUT_BUF + m*16, b);
            if (b !== exp_beats[m]) begin
                for (q = 0; q < 16; q = q + 1) begin
                    if (b[q*8 +: 8] !== exp_beats[m][q*8 +: 8]) begin
                        if (nerr < 16)
                            $display("[FAIL] byte %0d got=%02h exp=%02h",
                                     m*16+q, b[q*8 +: 8], exp_beats[m][q*8 +: 8]);
                        nerr = nerr + 1;
                    end
                end
            end
        end
        if (nerr != 0) begin
            $display("[FAIL] full_out: %0d/%0d bytes mismatched", nerr, N_OUT_BEATS*16);
            err_cnt = err_cnt + nerr;
        end else
            $display("[ ok ] full_out: %0d bytes all match", N_OUT_BEATS*16);

        $display("=== summary: errs=%0d cycles=%0d ===", err_cnt, cyc);
        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗：8 s 模拟时间
    initial begin
        #(64'd8000000000);
        $display("TB FAIL (timeout) adapter=%0d m8busy=%0d mboxbusy=%0d status=%08h cyc=%0d",
                 o_adapter_state, o_m8_busy, o_mbox_busy, o_mbox_status, cyc);
        $finish;
    end

endmodule
