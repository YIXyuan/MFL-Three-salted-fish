// -----------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
//
// Filename    : tb_ctrl_regs_v1_0.v
// Description : kosmo2_ctrl_regs_v1_0 自校验 testbench（M1 单元仿真）
//               TB 同时扮演 ctrl_fsm（假 FSM）: start_o 脉冲 -> busy 50 拍 -> done 单拍。
//               结束打印 TB PASS / TB FAIL（run_sim.py 据此判定）。
// 运行        : 见 sim/modelsim/sim_ctrl_regs.do
// Copyright (c) 2026 MFL FPGA project
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ctrl_regs_v1_0;

    // 时钟/复位
    reg aclk;
    reg rst_n;

    // AXI4-Lite
    reg  [31:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [31:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    // 对内（假 FSM 侧）
    wire        start_o, abort_o, irq_o;
    wire [31:0] in_addr_o, out_addr_o;
    wire [15:0] cfg_sel_o;
    reg         busy_r;                 // 假 FSM: busy
    reg         done_r;                 // 假 FSM: done 单拍
    wire        busy_i = busy_r;
    wire        done_i = done_r;

    integer err_cnt;
    integer start_cnt;                  // 统计 start_o 单拍脉冲次数
    reg [31:0] v;

    kosmo2_ctrl_regs_v1_0 #(
        .C_VERSION(32'h2026_0925)
    ) u_dut (
        .aclk(aclk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .start_o(start_o), .abort_o(abort_o),
        .busy_i(busy_i), .done_i(done_i),
        .in_addr_o(in_addr_o), .out_addr_o(out_addr_o),
        .cfg_sel_o(cfg_sel_o), .irq_o(irq_o)
    );

    // 100MHz 时钟
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // start 脉冲计数（每 accepted START 应恰好 1 拍）
    always @(posedge aclk)
        if (start_o) start_cnt = start_cnt + 1;

    // ---------------- 校验任务 ----------------
    task check32;
        input [31:0] got;
        input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("[FAIL] t=%0t got=%08h exp=%08h", $time, got, exp);
                err_cnt = err_cnt + 1;
            end else
                $display("[ ok ] got=%08h", got);
        end
    endtask

    task check1;
        input got;
        input exp;
        begin
            if (got !== exp) begin
                $display("[FAIL] t=%0t got=%b exp=%b", $time, got, exp);
                err_cnt = err_cnt + 1;
            end else
                $display("[ ok ] got=%b", got);
        end
    endtask

    // ---------------- AXI4-Lite 读写任务 ----------------
    task axi_write;
        input [31:0] addr;
        input [31:0] dat;
        begin
            @(posedge aclk);
            awaddr <= addr;  awvalid <= 1'b1;
            wdata  <= dat;   wstrb   <= 4'hf;  wvalid <= 1'b1;
            bready <= 1'b1;
            fork
                begin : w_aw
                    @(posedge aclk);
                    while (!awready) @(posedge aclk);
                    awvalid <= 1'b0;
                end
                begin : w_w
                    @(posedge aclk);
                    while (!wready) @(posedge aclk);
                    wvalid <= 1'b0;
                end
                begin : w_b
                    @(posedge aclk);
                    while (!bvalid) @(posedge aclk);
                    bready <= 1'b0;
                end
            join
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] dat;
        begin
            @(posedge aclk);
            araddr <= addr;  arvalid <= 1'b1;
            rready <= 1'b1;
            @(posedge aclk);
            while (!arready) @(posedge aclk);
            arvalid <= 1'b0;
            while (!rvalid)  @(posedge aclk);
            dat    = rdata;
            rready <= 1'b0;
        end
    endtask

    // ---------------- 假 ctrl_fsm ----------------
    // start_o 单拍 -> busy 50 拍 -> done 单拍（模拟一次"推理作业"耗时）
    reg [7:0] work_cnt;
    always @(posedge aclk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r   <= 1'b0;
            done_r   <= 1'b0;
            work_cnt <= 8'd0;
        end else begin
            done_r <= 1'b0;
            if (start_o) begin
                busy_r   <= 1'b1;
                work_cnt <= 8'd50;
            end else if (busy_r) begin
                if (work_cnt <= 8'd1) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else
                    work_cnt <= work_cnt - 8'd1;
            end
        end
    end

    // ---------------- 主测试序列 ----------------
    initial begin
        err_cnt   = 0;
        start_cnt = 0;
        awvalid = 1'b0;  wvalid = 1'b0;  bready = 1'b0;
        arvalid = 1'b0;  rready = 1'b0;
        rst_n   = 1'b0;
        repeat (5) @(posedge aclk);
        rst_n = 1'b1;
        repeat (2) @(posedge aclk);

        $display("=== T1: read-only regs after reset ===");
        axi_read(32'h0000_0018, v);  check32(v, 32'h2026_0925);   // VERSION
        axi_read(32'h0000_0004, v);  check32(v, 32'h0000_0000);   // STATUS

        $display("=== T2: config regs write/readback ===");
        axi_write(32'h0000_0008, 32'h0030_1000);
        axi_read (32'h0000_0008, v);  check32(v, 32'h0030_1000);
        axi_write(32'h0000_000C, 32'h0030_8000);
        axi_read (32'h0000_000C, v);  check32(v, 32'h0030_8000);
        axi_write(32'h0000_0010, 32'h0000_0005);
        axi_read (32'h0000_0010, v);  check32(v, 32'h0000_0005);
        axi_write(32'h0000_0014, 32'h0000_0001);
        axi_read (32'h0000_0014, v);  check32(v, 32'h0000_0001);
        check1(in_addr_o === 32'h0030_1000, 1'b1);   // 配置直通引脚
        check1(cfg_sel_o === 16'h0005,      1'b1);

        $display("=== T3: START -> BUSY -> DONE -> IRQ ===");
        axi_write(32'h0000_0000, 32'h0000_0001);   // START
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0001);  // BUSY=1
        wait (done_r === 1'b1);
        @(posedge aclk);
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0002);  // DONE=1, BUSY=0
        check1(irq_o, 1'b1);                        // IRQ_EN=1 -> 电平中断拉起

        $display("=== T4: CLR clears DONE/IRQ ===");
        axi_write(32'h0000_0000, 32'h0000_0004);
        @(posedge aclk);
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0000);
        check1(irq_o, 1'b0);

        $display("=== T5: IRQ_EN=0 masks irq, re-enable restores level ===");
        axi_write(32'h0000_0014, 32'h0000_0000);
        axi_write(32'h0000_0000, 32'h0000_0001);   // START
        wait (done_r === 1'b1);
        @(posedge aclk);
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0002);  // DONE 照常置位
        check1(irq_o, 1'b0);                        // 但中断被屏蔽
        axi_write(32'h0000_0014, 32'h0000_0001);   // 再使能
        @(posedge aclk);
        check1(irq_o, 1'b1);                        // 电平语义: 立即恢复
        axi_write(32'h0000_0000, 32'h0000_0004);   // CLR
        @(posedge aclk);
        check1(irq_o, 1'b0);

        $display("=== T6: START while BUSY -> ERR ===");
        axi_write(32'h0000_0000, 32'h0000_0001);   // 正常 START, 假 FSM 忙 50 拍
        axi_write(32'h0000_0000, 32'h0000_0001);   // 忙中再启 -> 被拒并置 ERR
        wait (done_r === 1'b1);
        @(posedge aclk);
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0006);  // ERR|DONE
        axi_write(32'h0000_0000, 32'h0000_0004);   // CLR
        @(posedge aclk);
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0000);

        $display("=== T7: ABORT set / CLR clear ===");
        axi_write(32'h0000_0000, 32'h0000_0002);
        @(posedge aclk);  check1(abort_o, 1'b1);
        axi_write(32'h0000_0000, 32'h0000_0004);
        @(posedge aclk);  check1(abort_o, 1'b0);

        $display("=== T8: unmapped / read-only writes ignored ===");
        axi_write(32'h0000_0040, 32'hdead_beef);   // 未映射地址
        axi_write(32'h0000_0004, 32'h0000_00ff);   // STATUS 只读
        axi_read (32'h0000_0008, v);  check32(v, 32'h0030_1000);  // 未被破坏
        axi_read (32'h0000_0004, v);  check32(v, 32'h0000_0000);

        $display("=== summary ===");
        $display("start_o pulse count = %0d (exp 3: T3/T5/T6 accepted, T6 2nd refused)",
                 start_cnt);
        if (start_cnt !== 3) err_cnt = err_cnt + 1;

        if (err_cnt == 0)
            $display("TB PASS");
        else
            $display("TB FAIL (%0d errors)", err_cnt);
        $finish;
    end

    // 看门狗: 500us 超时
    initial begin
        #500_000;
        $display("TB FAIL (timeout)");
        $finish;
    end

endmodule
