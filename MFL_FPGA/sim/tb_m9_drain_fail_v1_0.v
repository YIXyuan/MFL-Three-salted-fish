// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_m9_drain_fail_v1_0.v
// Description : M9 软复位“排空超时”用例（RESET_FAIL）
//   * 顶层把 C_DRAIN_CYC 缩到 2000 拍（20us@100MHz 仿真），BUSY 帧的 M8.abort
//     在层边界需要 ~10ms，必然排空超时
//   * 期望：适配器强制 core reset → 写 STATUS=0x6（RESET_FAIL）→ 清 CTRL
//     → 最后清 RESET=0
//   * 其余环境（SPS 32MB 模型/缩放配置/输入）与主 TB 相同
//   运行：与 tb_m9_top_v1_0 同一个 .do（sim_m9_top.do 依次跑两个 TB）
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_m9_drain_fail_v1_0;

    localparam [31:0] MBOX    = 32'h0030_1000;
    localparam [31:0] IN_BUF  = 32'h0030_2000;
    localparam [31:0] OUT_BUF = 32'h0047_0000;
    localparam integer N_IN   = 49152;

    reg aclk;
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

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
    wire        sps_resetn;

    reg [7:0]   inbytes [0:N_IN-1];
    reg [127:0] tcfg [0:9];
    integer err_cnt;
    integer i, j;
    integer ok;
    reg [31:0] s;
    reg [127:0] b;

    kosmo2_m9_top_v1_0 #(
        .C_EXT_WORDS_EN(1),
        .C_DRAIN_CYC(2000),            // 20us：M8 abort 需要 ~10ms -> 必超时
        .C_DONE_HOLD_CYC(5000000)      // 本 TB 无 pending；给个非零值
    ) u_m9 (
        .i_aclk(aclk), .i_sps0_resetn(sps_resetn), .o_sps0_clk(),
        .sps0_awvalid(sps0_awvalid), .sps0_awready(sps0_awready),
        .sps0_awid(sps0_awid), .sps0_awaddr(sps0_awaddr), .sps0_awlen(sps0_awlen),
        .sps0_awsize(sps0_awsize), .sps0_awburst(sps0_awburst),
        .sps0_awlock(sps0_awlock), .sps0_awcache(sps0_awcache),
        .sps0_awprot(sps0_awprot), .sps0_awqos(sps0_awqos),
        .sps0_wvalid(sps0_wvalid), .sps0_wready(sps0_wready),
        .sps0_wdata(sps0_wdata), .sps0_wstrb(sps0_wstrb), .sps0_wlast(sps0_wlast),
        .sps0_bvalid(sps0_bvalid), .sps0_bid(sps0_bid),
        .sps0_bresp(sps0_bresp), .sps0_bready(sps0_bready),
        .sps0_arvalid(sps0_arvalid), .sps0_arready(sps0_arready),
        .sps0_arid(sps0_arid), .sps0_araddr(sps0_araddr), .sps0_arlen(sps0_arlen),
        .sps0_arsize(sps0_arsize), .sps0_arburst(sps0_arburst),
        .sps0_arlock(sps0_arlock), .sps0_arcache(sps0_arcache),
        .sps0_arprot(sps0_arprot), .sps0_arqos(sps0_arqos),
        .sps0_rvalid(sps0_rvalid), .sps0_rid(sps0_rid),
        .sps0_rdata(sps0_rdata), .sps0_rresp(sps0_rresp), .sps0_rlast(sps0_rlast),
        .sps0_rready(sps0_rready),
        .o_m8_busy(o_m8_busy), .o_m8_done(o_m8_done), .o_m8_err(o_m8_err),
        .o_mbox_status(o_mbox_status), .o_adapter_state(o_adapter_state),
        .o_mbox_busy(o_mbox_busy),
        .o_bist_busy(), .o_bist_done(), .o_bist_pass()
    );

    kosmo2_pu_sps_model_v1_0 #(
        .C_DW(128), .C_IDW(4), .C_MEM_D(21), .C_SEED(32'h0bad_f00d)
    ) u_sps (
        .aclk(aclk), .resetn(sps_resetn),
        .awvalid(sps0_awvalid), .awready(sps0_awready), .awid(sps0_awid),
        .awaddr(sps0_awaddr), .awlen(sps0_awlen),
        .wvalid(sps0_wvalid), .wready(sps0_wready),
        .wdata(sps0_wdata), .wstrb(sps0_wstrb), .wlast(sps0_wlast),
        .bvalid(sps0_bvalid), .bready(sps0_bready),
        .bid(sps0_bid), .bresp(sps0_bresp),
        .arvalid(sps0_arvalid), .arready(sps0_arready), .arid(sps0_arid),
        .araddr(sps0_araddr), .arlen(sps0_arlen),
        .rvalid(sps0_rvalid), .rready(sps0_rready), .rid(sps0_rid),
        .rdata(sps0_rdata), .rresp(sps0_rresp), .rlast(sps0_rlast)
    );

    task mb_peek;
        input  [31:0] off;
        output [31:0] data;
        reg [31:0]  a;
        reg [127:0] bb;
        begin
            a = MBOX + (off & 32'hFFFF_FFF0);
            u_sps.peek_beat(a, bb);
            case (off[3:2])
                2'd0:    data = bb[31:0];
                2'd1:    data = bb[63:32];
                2'd2:    data = bb[95:64];
                default: data = bb[127:96];
            endcase
        end
    endtask

    task mb_poke;
        input [31:0] off;
        input [31:0] data;
        reg [31:0]  a;
        reg [127:0] bb;
        begin
            a = MBOX + (off & 32'hFFFF_FFF0);
            u_sps.peek_beat(a, bb);
            case (off[3:2])
                2'd0:    bb[31:0]   = data;
                2'd1:    bb[63:32]  = data;
                2'd2:    bb[95:64]  = data;
                default: bb[127:96] = data;
            endcase
            u_sps.poke_beat(a, bb);
        end
    endtask

    task wait_status;
        input  [31:0] want;
        input  integer max_polls;
        output integer ok;
        integer n;
        reg [31:0] ss;
        begin
            ok = 0;
            for (n = 0; n < max_polls; n = n + 1) begin
                mb_peek(32'h10, ss);
                if (ss === want) begin ok = 1; n = max_polls; end
                else #100_000;
            end
        end
    endtask

    task wait_reset0;
        input  integer max_polls;
        output integer ok;
        integer n;
        reg [31:0] ss;
        begin
            ok = 0;
            for (n = 0; n < max_polls; n = n + 1) begin
                mb_peek(32'h1C, ss);
                if (ss === 32'h0) begin ok = 1; n = max_polls; end
                else #100_000;
            end
        end
    endtask

    initial begin
        err_cnt = 0;
        for (i = 0; i < 3; i = i + 1) u_sps.poke_beat(MBOX + i*16, 128'd0);
        // 有效 IN/OUT 触发 boot（无 magic）
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h0C, 32'h0);

        $readmemh("../vec/layer_cfg_test.hex", tcfg);
        #1;
        for (i = 0; i < 10; i = i + 1) u_m9.u_m8.u_cfg.rom[i] = tcfg[i];

        $readmemh("../vec/m8_in.hex", inbytes);
        for (i = 0; i < N_IN; i = i + 16) begin
            b = 128'd0;
            for (j = 0; j < 16; j = j + 1) b[j*8 +: 8] = inbytes[i+j];
            u_sps.poke_beat(IN_BUF + i, b);
        end

        $timeformat(-9, 0, " ns", 12);
        #5_000_000;                       // boot/VERSION

        $display("=== T6: soft reset drain timeout -> RESET_FAIL ===");
        mb_poke(32'h00, IN_BUF);
        mb_poke(32'h04, OUT_BUF);
        mb_poke(32'h14, 32'h0000_0300);   // LAYER=0x300|0
        mb_poke(32'h0C, 32'h1);
        wait_status(32'h1, 3000, ok);
        if (!ok) begin
            $display("[FAIL] T6 no BUSY (status=%08h st=%0d)", o_mbox_status, o_adapter_state);
            err_cnt = err_cnt + 1;
        end

        mb_poke(32'h1C, 32'h1);           // 软复位（BUSY 中）
        wait_reset0(2000, ok);            // 200 ms
        if (!ok) begin
            $display("[FAIL] T6 RESET not cleared");
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T6 RESET self-cleared");

        mb_peek(32'h10, s);
        if (s !== 32'h6) begin
            $display("[FAIL] T6 STATUS=%08h exp=0x6 (RESET_FAIL)", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T6 STATUS=0x6 (RESET_FAIL)");
        mb_peek(32'h0C, s);
        if (s !== 32'h0) begin
            $display("[FAIL] T6 CTRL not cleared: %08h", s);
            err_cnt = err_cnt + 1;
        end else
            $display("[ ok ] T6 CTRL=0");

        $display("=== summary: errs=%0d ===", err_cnt);
        if (err_cnt == 0) $display("TB PASS");
        else              $display("TB FAIL");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TB FAIL (timeout) adapter=%0d m8busy=%0d mboxbusy=%0d status=%08h",
                 o_adapter_state, o_m8_busy, o_mbox_busy, o_mbox_status);
        $finish;
    end

endmodule
