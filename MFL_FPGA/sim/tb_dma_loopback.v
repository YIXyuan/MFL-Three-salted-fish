// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_dma_loopback.v
// Description : M2 闭环回环自校验 testbench: kosmo2_axi_dma_rd -> 流 -> kosmo2_axi_dma_wr
//               * 流对接(按需求直连): u_rd.m_data/m_valid/m_last -> u_wr.s_data/s_valid/s_last
//                                      u_wr.s_ready -> u_rd.m_ready
//               * 双通道 AXI4 从机内存模型 axi4_slv_mem_model: AR/R 与 AW/W/B 独立 FSM,
//                 mem[i] = i(低 8 位), 内置协议断言(对齐/不跨4KB/len上限/size/burst/
//                 wlast 位置/wstrb 全1), rnd_en=1 时各通道随机延迟注入(反压)
//               * 反压说明: m_ready 与 s_ready 为同一根网线(直连), 随机反压来源 =
//                 写主 s_ready 固有间隙(AW/B/NEXT) + 从机随机延迟透传(wready 反压
//                 -> s_ready=0 -> m_ready=0), 无需在直连线上插门
//               * 校验: 每笔回环完成后, 从机内存里 dst 区域与 src 区域逐字节比对,
//                 必须一字节不差; 流侧另校验 beat 数与 m_last 恰好一次
// 运行        : python tools/run_sim.py --ip ip/kosmo2_axi_dma_wr --do sim_loopback.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_dma_loopback;

    reg         aclk;
    reg         rst_n;
    reg         rnd_en;                  // 从机随机延迟开关(反压注入)

    // ---- 命令接口 ----
    reg  [31:0] rd_base, wr_base;
    reg  [23:0] rd_len,  wr_len;
    reg         rd_valid, wr_valid;
    wire        rd_ready, wr_ready;
    wire        rd_busy, wr_busy;

    // ---- 流直连 ----
    wire [127:0] strm_data;
    wire         strm_valid, strm_last, strm_ready;

    // ---- 读通道 AXI ----
    wire [31:0] araddr;
    wire [7:0]  arlen;
    wire [2:0]  arsize, arprot;
    wire [1:0]  arburst;
    wire        arvalid, arready;
    wire [127:0] rdata;
    wire [1:0]  rresp;
    wire        rlast, rvalid, rready;

    // ---- 写通道 AXI ----
    wire [31:0] awaddr;
    wire [7:0]  awlen;
    wire [2:0]  awsize, awprot;
    wire [1:0]  awburst;
    wire        awvalid, awready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire        wlast, wvalid, wready;
    wire [1:0]  bresp;
    wire        bvalid, bready;

    integer err_cnt;

    // ================= DUT 例化 =================
    kosmo2_axi_dma_rd_v1_0 u_rd (
        .aclk(aclk), .rst_n(rst_n),
        .cmd_base_addr(rd_base), .cmd_byte_len(rd_len),
        .cmd_valid(rd_valid), .cmd_ready(rd_ready),
        .m_data(strm_data), .m_valid(strm_valid), .m_last(strm_last),
        .m_ready(strm_ready),                       // 直连: 写主 s_ready
        .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_arburst(arburst), .m_axi_arprot(arprot),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .busy_o(rd_busy)
    );

    kosmo2_axi_dma_wr_v1_0 u_wr (
        .aclk(aclk), .rst_n(rst_n),
        .cmd_base_addr(wr_base), .cmd_byte_len(wr_len),
        .cmd_valid(wr_valid), .cmd_ready(wr_ready),
        .s_data(strm_data), .s_valid(strm_valid), .s_last(strm_last),
        .s_ready(strm_ready),                       // 直连: 反压回读主
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_awprot(awprot),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .busy_o(wr_busy)
    );

    axi4_slv_mem_model #(.C_DW(128), .MEM_BITS(17)) u_mem (
        .aclk(aclk), .rst_n(rst_n), .rnd_en(rnd_en),
        .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ================= 流侧监视: beat 计数 + m_last 统计 =================
    integer strm_beats, strm_last_cnt;
    always @(posedge aclk) begin
        if (rst_n && strm_valid && strm_ready) begin
            strm_beats = strm_beats + 1;
            if (strm_last) strm_last_cnt = strm_last_cnt + 1;
        end
    end

    // ================= 校验任务 =================
    // 流侧: beat 数与 m_last 恰好一次; 内存侧: dst 与 src 逐字节比对
    task check_xfer;
        input [31:0] src;
        input [31:0] dst;
        input [23:0] len;
        integer k, bad;
        begin
            if (strm_beats !== len >> 4) begin
                $display("[FAIL] stream beats=%0d exp=%0d", strm_beats, len >> 4);
                err_cnt = err_cnt + 1;
            end
            if (strm_last_cnt !== 1) begin
                $display("[FAIL] stream m_last count=%0d exp=1", strm_last_cnt);
                err_cnt = err_cnt + 1;
            end
            bad = 0;
            for (k = 0; k < len; k = k + 1) begin
                if (u_mem.mem[dst + k] !== u_mem.mem[src + k]) begin
                    if (bad < 4)
                        $display("[FAIL] byte %0d: dst[%08h]=%02h src[%08h]=%02h",
                                 k, dst + k, u_mem.mem[dst + k], src + k, u_mem.mem[src + k]);
                    bad = bad + 1;
                end
            end
            if (bad != 0) begin
                $display("[FAIL] loopback %0d/%0d bytes mismatched", bad, len);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // ================= 回环任务: 同拍发 rd/wr 命令, 等两侧完成 =================
    task loopback;
        input [31:0] src;
        input [31:0] dst;
        input [23:0] len;
        integer k;
        begin
            // 预填干扰图案: dst 初值与 src 规律不同 => 字节比对通过 <=> 确实写入
            for (k = 0; k < len; k = k + 1)
                u_mem.mem[dst + k] = 8'h5A;
            strm_beats    = 0;
            strm_last_cnt = 0;
            @(posedge aclk);
            rd_base  <= src;  rd_len  <= len;  rd_valid  <= 1'b1;
            wr_base  <= dst;  wr_len  <= len;  wr_valid  <= 1'b1;
            @(posedge aclk);
            while (!rd_ready) @(posedge aclk);          // 读主命令握手
            rd_valid <= 1'b0;
            while (!wr_ready) @(posedge aclk);          // 写主命令握手
            wr_valid <= 1'b0;
            @(posedge aclk);        // 让 accept 的 NBA 生效, busy 才可见
            // 等待次序: 先等 wr busy 拉起(rd 完成必晚于 wr 拉起), 再等 rd 回落,
            // 最后等 wr 回落 —— 防握手当拍 busy 尚未可见导致 wait 秒过(踩过的坑)
            wait (wr_busy == 1'b1);
            wait (rd_busy  == 1'b0);
            wait (wr_busy  == 1'b0);
            repeat (2) @(posedge aclk);
        end
    endtask

    // ================= 主测试序列 =================
    initial begin
        err_cnt      = 0;
        strm_beats   = 0;
        strm_last_cnt= 0;
        rd_valid     = 1'b0;  wr_valid  = 1'b0;
        rd_base      = 32'h0; wr_base   = 32'h0;
        rd_len       = 24'h0; wr_len    = 24'h0;
        rnd_en       = 1'b0;
        rst_n        = 1'b0;
        $timeformat(-9, 0, " ns", 12);
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: minimal loopback 16B, rd@0x1000 -> wr@0x8000 (fast) ===");
        loopback(32'h0000_1000, 32'h0000_8000, 24'd16);
        check_xfer(32'h0000_1000, 32'h0000_8000, 24'd16);

        $display("=== T2: 1KB loopback, rd@0x1000 -> wr@0x8000 (fast, 4 bursts) ===");
        loopback(32'h0000_1000, 32'h0000_8000, 24'h000400);
        check_xfer(32'h0000_1000, 32'h0000_8000, 24'h000400);

        $display("=== T3: 512B, src@0x0FF0 + dst@0x9FF0 both cross 4KB (fast) ===");
        loopback(32'h0000_0FF0, 32'h0000_9FF0, 24'h000200);
        check_xfer(32'h0000_0FF0, 32'h0000_9FF0, 24'h000200);

        $display("=== T4: 8KB long, rd@0x0E00 -> wr@0x8C00, rnd_en=1 (random backpressure) ===");
        rnd_en = 1'b1;
        loopback(32'h0000_0E00, 32'h0000_8C00, 24'h002000);
        check_xfer(32'h0000_0E00, 32'h0000_8C00, 24'h002000);

        $display("=== T5: back-to-back 256B x2 (rnd_en=1) ===");
        loopback(32'h0000_3000, 32'h0000_A000, 24'h000100);
        check_xfer(32'h0000_3000, 32'h0000_A000, 24'h000100);
        loopback(32'h0000_3100, 32'h0000_A100, 24'h000100);
        check_xfer(32'h0000_3100, 32'h0000_A100, 24'h000100);
        rnd_en = 1'b0;

        $display("=== summary: model protocol errs=%0d, tb errs=%0d ===",
                 u_mem.err_cnt, err_cnt);
        if (err_cnt == 0 && u_mem.err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #2_000_000;
        $display("TB FAIL (timeout)");
        $finish;
    end

endmodule

// =============================================================================
// 双通道 AXI4 从机内存模型 (AR/R 与 AW/W/B 独立 FSM, 可并发)
//   * mem[i] = i 的低 8 位; 读出低字节低 lane, 写入按 lane 拆字节
//   * 协议断言: 16B 对齐 / 单笔不跨 4KB / len<=15 / size==4 / burst==INCR
//               wlast 位置(仅在尾拍且尾拍必有) / wstrb 全 1
//   * rnd_en=1: AR/AW 随机 0~3 拍延迟 + beat 间偶发气泡 + B 响应随机延迟
//     rnd_en=0: 全快速路径(零延迟)
// =============================================================================
module axi4_slv_mem_model #(
    parameter integer C_DW     = 128,
    parameter integer MEM_BITS = 17                  // 128KB 地址空间
)(
    input  wire                aclk,
    input  wire                rst_n,
    input  wire                rnd_en,
    // ---- 读地址通道 ----
    input  wire [31:0]         s_axi_araddr,
    input  wire [7:0]          s_axi_arlen,
    input  wire [2:0]          s_axi_arsize,
    input  wire [1:0]          s_axi_arburst,
    input  wire                s_axi_arvalid,
    output reg                 s_axi_arready,
    // ---- 读数据通道 ----
    output reg  [C_DW-1:0]     s_axi_rdata,
    output reg  [1:0]          s_axi_rresp,
    output reg                 s_axi_rlast,
    output reg                 s_axi_rvalid,
    input  wire                s_axi_rready,
    // ---- 写地址通道 ----
    input  wire [31:0]         s_axi_awaddr,
    input  wire [7:0]          s_axi_awlen,
    input  wire [2:0]          s_axi_awsize,
    input  wire [1:0]          s_axi_awburst,
    input  wire                s_axi_awvalid,
    output reg                 s_axi_awready,
    // ---- 写数据通道 ----
    input  wire [C_DW-1:0]     s_axi_wdata,
    input  wire [C_DW/8-1:0]   s_axi_wstrb,
    input  wire                s_axi_wlast,
    input  wire                s_axi_wvalid,
    output reg                 s_axi_wready,
    // ---- 写响应通道 ----
    output reg  [1:0]          s_axi_bresp,
    output reg                 s_axi_bvalid,
    input  wire                s_axi_bready
);
    // ---------------- 读侧 FSM ----------------
    localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_BEAT = 2'd2;
    reg [1:0]  r_st;
    reg [31:0] r_addr;
    reg [7:0]  r_len, r_beat;
    reg [2:0]  r_lat;

    // ---------------- 写侧 FSM ----------------
    localparam W_IDLE = 2'd0, W_WAIT = 2'd1, W_BEAT = 2'd2, W_B = 2'd3;
    reg [1:0]  w_st;
    reg [31:0] w_addr;
    reg [7:0]  w_len, w_beat;
    reg [2:0]  w_lat;

    reg [7:0]  mem [0:(1<<MEM_BITS)-1];
    integer    err_cnt, seed_r, seed_w, i, k;

    initial begin
        seed_r  = 32'h6001_0001;
        seed_w  = 32'h6001_0002;
        err_cnt = 0;
        for (i = 0; i < (1<<MEM_BITS); i = i + 1)
            mem[i] = i;                              // 低 8 位截断
    end

    task slv_fail;
        input [8*48-1:0] msg;
        begin
            $display("[FAIL] slv t=%0t %0s", $time, msg);
            err_cnt = err_cnt + 1;
        end
    endtask

    // 读数据组合生成: 当前地址 16 字节, 低字节低 lane
    always @* begin
        s_axi_rdata = {mem[r_addr+15], mem[r_addr+14], mem[r_addr+13], mem[r_addr+12],
                       mem[r_addr+11], mem[r_addr+10], mem[r_addr+9],  mem[r_addr+8],
                       mem[r_addr+7],  mem[r_addr+6],  mem[r_addr+5],  mem[r_addr+4],
                       mem[r_addr+3],  mem[r_addr+2],  mem[r_addr+1],  mem[r_addr]};
    end

    // rlast 组合生成(教训: 寄存式会差一拍, 见 M2 读主 TB 调试实录)
    always @* begin
        s_axi_rlast = (r_st == R_BEAT) && (r_beat == r_len);
    end

    // ---------------- 读侧: AR/R ----------------
    always @(posedge aclk) begin
        if (!rst_n) begin
            r_st <= R_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            r_addr <= 32'h0; r_len <= 8'h0; r_beat <= 8'h0; r_lat <= 3'd0;
        end else begin
            case (r_st)
            R_IDLE: begin
                s_axi_arready <= !rnd_en || (($random(seed_r) & 3) != 2'd0);
                if (s_axi_arvalid && s_axi_arready) begin
                    if (s_axi_araddr[3:0] !== 4'd0)  slv_fail("AR addr not 16B aligned");
                    if (s_axi_arlen > 8'd15)         slv_fail("AR len > 15");
                    if (s_axi_arsize !== 3'd4)       slv_fail("AR size != 3'd4");
                    if (s_axi_arburst !== 2'b01)     slv_fail("AR burst != INCR");
                    if (({1'b0, s_axi_araddr[11:0]} + {5'd0, s_axi_arlen, 4'd0}) > 13'h1000)
                                                     slv_fail("read burst crosses 4KB");
                    r_addr <= s_axi_araddr;
                    r_len  <= s_axi_arlen;
                    r_beat <= 8'd0;
                    r_lat  <= rnd_en ? ($random(seed_r) & 3'd3) : 3'd0;
                    s_axi_arready <= 1'b0;
                    r_st   <= R_WAIT;
                end
            end
            R_WAIT: begin
                if (r_lat == 3'd0) r_st <= R_BEAT;
                else               r_lat <= r_lat - 3'd1;
            end
            R_BEAT: begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                if (s_axi_rvalid && s_axi_rready) begin
                    if (r_beat == r_len) begin
                        s_axi_rvalid <= 1'b0;
                        r_st         <= R_IDLE;
                    end else begin
                        r_beat <= r_beat + 8'd1;
                        r_addr <= r_addr + 32'd16;
                        if (rnd_en && (($random(seed_r) & 7) == 3'd0)) begin
                            s_axi_rvalid <= 1'b0;            // 偶发气泡
                            r_st         <= R_WAIT;
                            r_lat        <= 3'd0;
                        end
                    end
                end
            end
            default: r_st <= R_IDLE;
            endcase
        end
    end

    // ---------------- 写侧: AW/W/B ----------------
    always @(posedge aclk) begin
        if (!rst_n) begin
            w_st <= W_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            w_addr <= 32'h0; w_len <= 8'h0; w_beat <= 8'h0; w_lat <= 3'd0;
        end else begin
            s_axi_wready <= 1'b0;    // 默认 0, 仅 W_BEAT 拉高 —— 防陈旧高电平假握手丢拍
            case (w_st)
            W_IDLE: begin
                s_axi_awready <= !rnd_en || (($random(seed_w) & 3) != 2'd0);
                if (s_axi_awvalid && s_axi_awready) begin
                    if (s_axi_awaddr[3:0] !== 4'd0)  slv_fail("AW addr not 16B aligned");
                    if (s_axi_awlen > 8'd15)         slv_fail("AW len > 15");
                    if (s_axi_awsize !== 3'd4)       slv_fail("AW size != 3'd4");
                    if (s_axi_awburst !== 2'b01)     slv_fail("AW burst != INCR");
                    if (({1'b0, s_axi_awaddr[11:0]} + {5'd0, s_axi_awlen, 4'd0}) > 13'h1000)
                                                     slv_fail("write burst crosses 4KB");
                    w_addr <= s_axi_awaddr;
                    w_len  <= s_axi_awlen;
                    w_beat <= 8'd0;
                    w_lat  <= rnd_en ? ($random(seed_w) & 3'd3) : 3'd0;
                    s_axi_awready <= 1'b0;
                    w_st   <= W_WAIT;
                end
            end
            W_WAIT: begin
                if (w_lat == 3'd0) w_st <= W_BEAT;
                else               w_lat <= w_lat - 3'd1;
            end
            W_BEAT: begin
                s_axi_wready <= !rnd_en || (($random(seed_w) & 3) != 2'd0);
                if (s_axi_wvalid && s_axi_wready) begin
                    // ---- wlast 位置断言: 仅尾拍为 1, 且尾拍必须为 1 ----
                    if ((w_beat != w_len) && s_axi_wlast)
                        slv_fail("wlast on non-last beat");
                    if ((w_beat == w_len) && !s_axi_wlast)
                        slv_fail("wlast missing on last beat");
                    if (s_axi_wstrb !== {C_DW/8{1'b1}})
                        slv_fail("wstrb != all-1");
                    // ---- 落内存: 按 lane 拆 16 字节(低字节低 lane) ----
                    for (k = 0; k < 16; k = k + 1)
                        mem[w_addr + k] = s_axi_wdata[k*8 +: 8];
                    if (w_beat == w_len) begin
                        s_axi_wready <= 1'b0;
                        w_lat        <= rnd_en ? ($random(seed_w) & 3'd3) : 3'd0;
                        w_st         <= W_B;             // 等 B 响应才算完成
                    end else begin
                        w_beat <= w_beat + 8'd1;
                        w_addr <= w_addr + 32'd16;
                    end
                end
            end
            W_B: begin
                if (w_lat != 3'd0) begin
                    w_lat <= w_lat - 3'd1;
                end else begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    if (s_axi_bvalid && s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        w_st         <= W_IDLE;
                    end
                end
            end
            default: w_st <= W_IDLE;
            endcase
        end
    end

endmodule
