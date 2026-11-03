// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_axi_dma_rd_v1_0.v
// Description : kosmo2_axi_dma_rd_v1_0 自校验 testbench（M2 读主）
//               内置最小 AXI4 从机内存模型（带协议断言：16B 对齐 / 不跨 4KB /
//               arlen<=15 / arsize=4 / arburst=INCR）。
//               用例覆盖：基本读 / 满笔 16 beat / 跨 4KB 切笔 / 长传输多笔 /
//               随机反压不丢数 / 零长度防呆 / 背靠背命令。打印 TB PASS / TB FAIL。
// 运行        : python tools/run_sim.py --ip ip/kosmo2_axi_dma_rd --do sim_dma_rd.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_axi_dma_rd_v1_0;

    reg         aclk;
    reg         rst_n;
    reg  [31:0] cmd_base_addr;
    reg  [23:0] cmd_byte_len;
    reg         cmd_valid;
    wire        cmd_ready;
    wire [127:0] m_data;
    wire        m_valid, m_last;
    reg         m_ready;
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire        m_axi_arvalid;
    wire        m_axi_arready;
    wire [1:0]  m_axi_arburst;
    wire [2:0]  m_axi_arprot;
    wire [127:0] m_axi_rdata;
    wire [1:0]  m_axi_rresp;
    wire        m_axi_rlast;
    wire        m_axi_rvalid;
    wire        m_axi_rready;
    wire        busy_o;

    integer err_cnt;
    integer seed_rdy;

    // ---- 接收缓存与统计 ----
    reg [127:0] rx_mem [0:4095];
    integer     rx_beats;
    integer     last_seen_cnt;
    integer     last_at;
    reg         in_xfer;
    integer     xfer_len_beats;

    kosmo2_axi_dma_rd_v1_0 u_dut (
        .aclk(aclk), .rst_n(rst_n),
        .cmd_base_addr(cmd_base_addr), .cmd_byte_len(cmd_byte_len),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .m_data(m_data), .m_valid(m_valid), .m_last(m_last), .m_ready(m_ready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arburst(m_axi_arburst), .m_axi_arprot(m_axi_arprot),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .busy_o(busy_o)
    );

    axi4_slv_rd_mem_model u_slv (
        .aclk(aclk), .rst_n(rst_n),
        .s_axi_araddr(m_axi_araddr), .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize), .s_axi_arburst(m_axi_arburst),
        .s_axi_arvalid(m_axi_arvalid), .s_axi_arready(m_axi_arready),
        .s_axi_rdata(m_axi_rdata), .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast), .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready)
    );

    initial aclk = 1'b0;
    always #5 aclk = ~aclk;                      // 100MHz 仿真时钟（功能与时序无关）

    // ---- m_ready 驱动: ready_mode=0 恒 ready(满带宽); =1 随机(75% ready) ----
    reg ready_mode;
    always @(posedge aclk) begin
        if (!rst_n)           m_ready <= 1'b0;
        else if (!ready_mode) m_ready <= 1'b1;
        else                  m_ready <= (($random(seed_rdy) & 3) != 2'd0);
    end

    // ---- 期望数据: 模型内存规律 mem[i]=i 的低 8 位, 低字节在低 lane ----
    function [127:0] exp_beat;
        input [31:0] addr;
        integer k;
        reg [127:0] tmp;
        begin
            tmp = 128'h0;
            for (k = 0; k < 16; k = k + 1)
                tmp[k*8 +: 8] = addr + k;        // 截断到 8bit = (addr+k) mod 256
            exp_beat = tmp;
        end
    endfunction

    // ---- 流收集器: 每个被接受的 beat 存档并统计 ----
    always @(posedge aclk) begin
        if (rst_n && m_valid && m_ready) begin
            if (!in_xfer) begin
                $display("[FAIL] t=%0t unexpected stream beat (no cmd in flight)", $time);
                err_cnt = err_cnt + 1;
            end else begin
                rx_mem[rx_beats] = m_data;
                if (m_last) begin
                    last_seen_cnt = last_seen_cnt + 1;
                    last_at = rx_beats;
                end
                if (!busy_o) begin
                    $display("[FAIL] t=%0t stream beat while busy_o=0", $time);
                    err_cnt = err_cnt + 1;
                end
                rx_beats = rx_beats + 1;
                if (rx_beats == xfer_len_beats) in_xfer = 1'b0;   // 收满即关
            end
        end
    end

    // ---- 一笔传输的完整性校验 ----
    task check_xfer;
        input [31:0] base;
        input [23:0] len_bytes;
        integer n, k, bad;
        begin
            n   = len_bytes >> 4;
            bad = 0;
            if (rx_beats !== n) begin
                $display("[FAIL] beat count=%0d exp=%0d", rx_beats, n);
                err_cnt = err_cnt + 1;
            end
            for (k = 0; k < n; k = k + 1) begin
                if (rx_mem[k] !== exp_beat(base + k*16)) begin
                    if (bad < 4)
                        $display("[FAIL] beat %0d got=%h exp=%h",
                                 k, rx_mem[k], exp_beat(base + k*16));
                    bad = bad + 1;
                end
            end
            if (bad > 0) begin
                $display("[FAIL] %0d beats mismatched", bad);
                err_cnt = err_cnt + 1;
            end
            if (last_seen_cnt !== 1) begin
                $display("[FAIL] m_last count=%0d exp=1", last_seen_cnt);
                err_cnt = err_cnt + 1;
            end else if (last_at !== n-1) begin
                $display("[FAIL] m_last at beat %0d exp=%0d", last_at, n-1);
                err_cnt = err_cnt + 1;
            end
            rx_beats      = 0;
            last_seen_cnt = 0;
            last_at       = -1;
        end
    endtask

    // ---- 发一笔命令(握手: valid 保持到 ready), len!=0 时打开收集 ----
    task dma_cmd;
        input [31:0] base;
        input [23:0] len;
        integer guard;
        begin
            @(posedge aclk);
            cmd_base_addr <= base;
            cmd_byte_len  <= len;
            cmd_valid     <= 1'b1;
            @(posedge aclk);
            while (!cmd_ready) @(posedge aclk);  // DUT 在本拍同我们一并采样握手
            cmd_valid <= 1'b0;
            guard = 0;
            while (!busy_o && guard < 100) begin
                @(posedge aclk);
                guard = guard + 1;
            end
            if (len != 24'd0) begin
                in_xfer        = 1'b1;
                xfer_len_beats = len >> 4;
            end
        end
    endtask

    // ---- 等传输完成(收集完 + busy 回落) ----
    task dma_wait_done;
        begin
            wait (in_xfer == 1'b0);
            wait (busy_o == 1'b0);
            repeat (2) @(posedge aclk);
        end
    endtask

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt        = 0;
        seed_rdy       = 32'hA5A5_0002;
        rx_beats       = 0;
        last_seen_cnt  = 0;
        last_at        = -1;
        in_xfer        = 1'b0;
        xfer_len_beats = 0;
        ready_mode     = 1'b0;
        cmd_valid      = 1'b0;
        cmd_base_addr  = 32'h0;
        cmd_byte_len   = 24'h0;
        rst_n          = 1'b0;
        $timeformat(-9, 0, " ns", 12);           // 让 [FAIL] 的时间戳以 ns 可读
        repeat (4) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: reset idle state ===");
        if (busy_o !== 1'b0)    begin $display("[FAIL] busy_o!=0 after reset");    err_cnt = err_cnt+1; end
        if (cmd_ready !== 1'b1) begin $display("[FAIL] cmd_ready!=1 after reset"); err_cnt = err_cnt+1; end
        if (m_valid !== 1'b0)   begin $display("[FAIL] m_valid!=0 after reset");   err_cnt = err_cnt+1; end

        $display("=== T2: minimal read 16B @0x1000 (1 burst, arlen=0) ===");
        dma_cmd(32'h0000_1000, 24'd16);
        dma_wait_done;
        check_xfer(32'h0000_1000, 24'd16);
        if (u_slv.ar_cnt !== 1) begin $display("[FAIL] ar_cnt=%0d exp=1", u_slv.ar_cnt); err_cnt = err_cnt+1; end

        $display("=== T3: full burst 256B (16 beats, arlen=15) @0x1000 ===");
        dma_cmd(32'h0000_1000, 24'd256);
        dma_wait_done;
        check_xfer(32'h0000_1000, 24'd256);
        if (u_slv.ar_cnt !== 2) begin $display("[FAIL] ar_cnt=%0d exp=2", u_slv.ar_cnt); err_cnt = err_cnt+1; end

        $display("=== T4: 4KB boundary split: 64B @0x0FF0 -> burst(1)+burst(3) ===");
        dma_cmd(32'h0000_0FF0, 24'd64);
        dma_wait_done;
        check_xfer(32'h0000_0FF0, 24'd64);
        if (u_slv.ar_cnt !== 4) begin
            $display("[FAIL] ar_cnt=%0d exp=4 (64B split into 2 bursts)", u_slv.ar_cnt);
            err_cnt = err_cnt + 1;
        end

        $display("=== T5: long 6KB = 384 beats / 24 bursts, crosses 4KB @0x1000/0x1800 ===");
        dma_cmd(32'h0000_0800, 24'h001800);
        dma_wait_done;
        check_xfer(32'h0000_0800, 24'h001800);
        if (u_slv.ar_cnt !== 28) begin $display("[FAIL] ar_cnt=%0d exp=28", u_slv.ar_cnt); err_cnt = err_cnt+1; end

        $display("=== T6: random backpressure (75%% ready) 2KB @0x2000 ===");
        ready_mode = 1'b1;
        dma_cmd(32'h0000_2000, 24'h000800);
        dma_wait_done;
        check_xfer(32'h0000_2000, 24'h000800);
        ready_mode = 1'b0;

        $display("=== T7: zero-length command (fang-dai: no AR issued) ===");
        begin : t7
            integer ar0;
            ar0 = u_slv.ar_cnt;
            dma_cmd(32'h0000_3000, 24'd0);
            repeat (8) @(posedge aclk);
            if (u_slv.ar_cnt !== ar0) begin $display("[FAIL] zero-len cmd issued AR"); err_cnt = err_cnt+1; end
            if (busy_o !== 1'b0)      begin $display("[FAIL] busy not back to 0");     err_cnt = err_cnt+1; end
            if (rx_beats !== 0)       begin $display("[FAIL] unexpected beats on zero-len"); err_cnt = err_cnt+1; end
        end

        $display("=== T8: back-to-back commands ===");
        dma_cmd(32'h0000_4000, 24'd32);
        dma_wait_done;
        check_xfer(32'h0000_4000, 24'd32);
        dma_cmd(32'h0000_4020, 24'd48);
        dma_wait_done;
        check_xfer(32'h0000_4020, 24'd48);

        $display("=== summary: slv protocol errs=%0d, tb errs=%0d ===", u_slv.err_cnt, err_cnt);
        if (err_cnt == 0 && u_slv.err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL");
        $finish;
    end

    // 看门狗
    initial begin
        #200_000;
        $display("TB FAIL (timeout)");
        $finish;
    end

endmodule

// =============================================================================
// 最小 AXI4 从机（只读通道）内存模型
//   * mem[i] = i 的低 8 位, 读出低字节在低 lane（小端, 与 AXI 字节 lane 约定一致）
//   * 协议断言: 16B 对齐 / 单笔不跨 4KB / arlen<=15 / arsize==4 / arburst==INCR
//   * 行为: AR 随机 0~3 拍延迟; beat 间偶发气泡; rvalid 保持到 rready
//   * 不用 Kosmo2_IP 的 kosmo2_pu_sps_model 的原因: 那是完整 SPS 口模型(含写通道),
//     这里需要只读最小模型 + 4KB/对齐断言注入, M9 集成时再换真模型
// =============================================================================
module axi4_slv_rd_mem_model #(
    parameter integer C_DW     = 128,
    parameter integer MEM_BITS = 17                  // 128KB 地址空间
)(
    input  wire                aclk,
    input  wire                rst_n,
    input  wire [31:0]         s_axi_araddr,
    input  wire [7:0]          s_axi_arlen,
    input  wire [2:0]          s_axi_arsize,
    input  wire [1:0]          s_axi_arburst,
    input  wire                s_axi_arvalid,
    output reg                 s_axi_arready,
    output reg  [C_DW-1:0]     s_axi_rdata,
    output reg  [1:0]          s_axi_rresp,
    output reg                 s_axi_rlast,
    output reg                 s_axi_rvalid,
    input  wire                s_axi_rready
);
    localparam M_IDLE = 2'd0, M_WAIT = 2'd1, M_BEAT = 2'd2;
    reg [1:0]  mst;
    reg [31:0] addr_r;
    reg [7:0]  len_r, beat_r;
    reg [2:0]  lat;
    reg [7:0]  mem [0:(1<<MEM_BITS)-1];
    integer    err_cnt, ar_cnt, seed, i;

    initial begin
        seed    = 32'h5132_0260;
        err_cnt = 0;
        ar_cnt  = 0;
        for (i = 0; i < (1<<MEM_BITS); i = i + 1)
            mem[i] = i;                              // 截断取低 8 位
    end

    // 读数据组合生成: 当前地址的 16 字节（低字节低 lane）
    always @* begin
        s_axi_rdata = {mem[addr_r+15], mem[addr_r+14], mem[addr_r+13], mem[addr_r+12],
                       mem[addr_r+11], mem[addr_r+10], mem[addr_r+9],  mem[addr_r+8],
                       mem[addr_r+7],  mem[addr_r+6],  mem[addr_r+5],  mem[addr_r+4],
                       mem[addr_r+3],  mem[addr_r+2],  mem[addr_r+1],  mem[addr_r]};
    end

    // rlast 组合生成: 当前呈现的 beat 是本笔尾拍则拉高
    // (经验教训: 寄存式 "rlast <= (beat_r==len_r)" 会差一拍, 多 beat 突发尾拍丢失)
    always @* begin
        s_axi_rlast = (mst == M_BEAT) && (beat_r == len_r);
    end

    task slv_fail;
        input [8*48-1:0] msg;
        begin
            $display("[FAIL] slv t=%0t %0s", $time, msg);
            err_cnt = err_cnt + 1;
        end
    endtask

    always @(posedge aclk) begin
        if (!rst_n) begin
            mst           <= M_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            addr_r        <= 32'h0;
            len_r         <= 8'h0;
            beat_r        <= 8'h0;
            lat           <= 3'd0;
        end else begin
            case (mst)
            // ---- IDLE: 随机延迟接收 AR, 捕获时做协议断言 ----
            M_IDLE: begin
                s_axi_arready <= (($random(seed) & 3) != 2'd0);   // 75% 拍收
                if (s_axi_arvalid && s_axi_arready) begin
                    ar_cnt = ar_cnt + 1;
                    if (s_axi_araddr[3:0] !== 4'd0)
                        slv_fail("AR addr not 16B aligned");
                    if (s_axi_arlen > 8'd15)
                        slv_fail("AR len > 15 (C_MAX_BURST-1)");
                    if (s_axi_arsize !== 3'd4)
                        slv_fail("AR size != 3'd4");
                    if (s_axi_arburst !== 2'b01)
                        slv_fail("AR burst != INCR");
                    if (({1'b0, s_axi_araddr[11:0]} + {5'd0, s_axi_arlen, 4'd0}) > 13'h1000)
                        slv_fail("burst crosses 4KB");
                    addr_r        <= s_axi_araddr;
                    len_r         <= s_axi_arlen;
                    beat_r        <= 8'd0;
                    lat           <= $random(seed) & 3'd3;       // 0~3 拍首拍延迟
                    s_axi_arready <= 1'b0;
                    mst           <= M_WAIT;
                end
            end
            // ---- WAIT: 消化随机首拍延迟 ----
            M_WAIT: begin
                if (lat == 3'd0) mst <= M_BEAT;
                else             lat <= lat - 3'd1;
            end
            // ---- BEAT: 逐拍给数, rvalid 保持到 rready; 偶发气泡 ----
            M_BEAT: begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                if (s_axi_rvalid && s_axi_rready) begin
                    if (beat_r == len_r) begin                    // 本笔尾拍
                        s_axi_rvalid <= 1'b0;
                        mst          <= M_IDLE;
                    end else begin
                        beat_r <= beat_r + 8'd1;
                        addr_r <= addr_r + 32'd16;
                        if (($random(seed) & 7) == 3'd0) begin    // 12.5% 插气泡
                            s_axi_rvalid <= 1'b0;
                            mst          <= M_WAIT;
                            lat          <= 3'd0;
                        end
                    end
                end
            end
            default: mst <= M_IDLE;
            endcase
        end
    end
endmodule
