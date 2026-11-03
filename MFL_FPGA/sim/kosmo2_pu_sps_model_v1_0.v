//------------------------------------------------------------------------------
// Copyright (c) 2026 Kosmo2_IP project (IC Lab). MIT License.
//
// Filename : kosmo2_pu_sps_model_v1_0.v（仅仿真，不可综合）
// Version  : 1.0
// Description: PU_SPS 接口行为模型（AXI4 从机 + 内存阵列），模拟
//              "PU 内部总线 -> 硬核 DDR 控制器 -> DDR3" 的访问路径
//   - 单发写/读（前一事务完成后才接受下一个）
//   - 随机化：WREADY 停顿、B 延迟、AR 接受延迟、R 拍间空隙
//   - poke_beat/peek_beat 任务供 TB 模拟 ARM 侧直接写内存
//------------------------------------------------------------------------------
`timescale 1ns / 1ps

module kosmo2_pu_sps_model_v1_0 #(
    parameter integer C_DW       = 128,
    parameter integer C_IDW      = 4,
    parameter integer C_MEM_D    = 20,          // 内存条目数 log2（每条目 C_DW 位）
    parameter integer C_RST_CYC  = 10,          // 复位周期数
    parameter integer C_SEED     = 32'h5eed_1234
)(
    input  wire              aclk,
    output reg               resetn,            // 模拟 PU_SPSn_RESETN（PU 输出）
    // 写地址
    input  wire              awvalid,
    output wire              awready,
    input  wire [C_IDW-1:0]  awid,
    input  wire [31:0]       awaddr,
    input  wire [7:0]        awlen,
    // 写数据
    input  wire              wvalid,
    output wire              wready,
    input  wire [C_DW-1:0]   wdata,
    input  wire [C_DW/8-1:0] wstrb,
    input  wire              wlast,
    // 写响应
    output reg               bvalid,
    input  wire              bready,
    output reg  [C_IDW-1:0]  bid,
    output reg  [1:0]        bresp,
    // 读地址
    input  wire              arvalid,
    output wire              arready,
    input  wire [C_IDW-1:0]  arid,
    input  wire [31:0]       araddr,
    input  wire [7:0]        arlen,
    // 读数据
    output reg               rvalid,
    input  wire              rready,
    output reg  [C_IDW-1:0]  rid,
    output reg  [C_DW-1:0]   rdata,
    output reg  [1:0]        rresp,
    output reg               rlast
);

    localparam integer BYTES = C_DW / 8;

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam integer BEAT_SHIFT = clog2(BYTES);

    reg [C_DW-1:0] mem [0:(1<<C_MEM_D)-1];

    integer seed;
    integer wi;

    //--------------------------------------------------------------
    // 复位输出
    //--------------------------------------------------------------
    initial begin
        resetn = 1'b0;
        seed   = C_SEED;
        repeat (C_RST_CYC) @(posedge aclk);
        resetn = 1'b1;
    end

    //--------------------------------------------------------------
    // 写通道
    //--------------------------------------------------------------
    reg              wr_busy;
    reg [7:0]        w_cnt;         // 剩余拍数
    reg [31:0]       w_addr;        // 当前拍地址
    reg [C_IDW-1:0]  w_id;
    reg [2:0]        b_delay;
    reg              w_stall;       // 随机写停顿

    assign awready = !wr_busy;
    assign wready  = wr_busy & !w_stall;

    always @(posedge aclk or negedge resetn) begin
        if (!resetn)
            w_stall <= 1'b0;
        else if (($random(seed) % 8) == 0)
            w_stall <= 1'b1;
        else
            w_stall <= 1'b0;
    end

    always @(posedge aclk or negedge resetn) begin
        if (!resetn) begin
            wr_busy <= 1'b0;
            w_cnt   <= 8'd0;
            w_addr  <= 32'd0;
            w_id    <= {C_IDW{1'b0}};
            bvalid  <= 1'b0;
            bid     <= {C_IDW{1'b0}};
            bresp   <= 2'b00;
            b_delay <= 3'd0;
        end else begin
            // B 延迟递减（先于写拍接受，避免同周期赋值冲突）
            if (b_delay != 0)
                b_delay <= b_delay - 3'd1;
            // 接受 AW
            if (awvalid & awready) begin
                wr_busy <= 1'b1;
                w_cnt   <= awlen + 8'd1;
                w_addr  <= awaddr;
                w_id    <= awid;
            end
            // 接受写拍（按字节使能写入）
            if (wvalid & wready) begin
                for (wi = 0; wi < BYTES; wi = wi + 1)
                    if (wstrb[wi])
                        mem[(w_addr >> BEAT_SHIFT)][wi*8 +: 8] <= wdata[wi*8 +: 8];
                w_addr <= w_addr + BYTES;
                w_cnt  <= w_cnt - 8'd1;
                if (wlast)
                    b_delay <= ($random(seed) & 7);
            end
            // B 响应（wlast 后随机延迟）
            if (wr_busy & (w_cnt == 8'd0) & (b_delay == 0) & !bvalid) begin
                bvalid <= 1'b1;
                bid    <= w_id;
                bresp  <= 2'b00;
            end
            if (bvalid & bready) begin
                bvalid  <= 1'b0;
                wr_busy <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------
    // 读通道
    //--------------------------------------------------------------
    reg              rd_busy;
    reg [7:0]        r_cnt;         // 剩余拍数
    reg [31:0]       r_addr;
    reg [C_IDW-1:0]  r_id;
    reg [4:0]        ar_delay;

    assign arready = !rd_busy;

    always @(posedge aclk or negedge resetn) begin
        if (!resetn) begin
            rd_busy  <= 1'b0;
            r_cnt    <= 8'd0;
            r_addr   <= 32'd0;
            r_id     <= {C_IDW{1'b0}};
            rvalid   <= 1'b0;
            rdata    <= {C_DW{1'b0}};
            rresp    <= 2'b00;
            rlast    <= 1'b0;
            ar_delay <= 5'd0;
        end else begin
            // 接受 AR
            if (arvalid & arready) begin
                rd_busy  <= 1'b1;
                r_cnt    <= arlen + 8'd1;
                r_addr   <= araddr;
                r_id     <= arid;
                ar_delay <= 4 + ($random(seed) & 15);   // 4..19 周期读延迟
            end
            // 读延迟
            if (rd_busy && !rvalid && (ar_delay != 0))
                ar_delay <= ar_delay - 5'd1;
            // 发读数据
            if (rd_busy && (ar_delay == 0)) begin
                if (!rvalid) begin
                    rvalid <= 1'b1;
                    rdata  <= mem[r_addr >> BEAT_SHIFT];
                    rresp  <= 2'b00;
                    rlast  <= (r_cnt == 8'd1);
                    rid    <= r_id;
                end else if (rready) begin
                    r_addr <= r_addr + BYTES;
                    r_cnt  <= r_cnt - 8'd1;
                    if (r_cnt == 8'd1) begin
                        rvalid  <= 1'b0;
                        rlast   <= 1'b0;
                        rd_busy <= 1'b0;
                    end else begin
                        // 拍间随机空隙
                        if (($random(seed) & 3) == 0)
                            rvalid <= 1'b0;
                        rdata <= mem[(r_addr + BYTES) >> BEAT_SHIFT];
                        rlast <= (r_cnt == 8'd2);
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------
    // TB 直访内存（模拟 ARM 侧写共享内存）
    //--------------------------------------------------------------
    task poke_beat(input [31:0] addr, input [C_DW-1:0] data);
        begin
            mem[(addr >> BEAT_SHIFT) & ((1<<C_MEM_D)-1)] = data;
        end
    endtask

    task peek_beat(input [31:0] addr, output [C_DW-1:0] data);
        begin
            data = mem[(addr >> BEAT_SHIFT) & ((1<<C_MEM_D)-1)];
        end
    endtask

endmodule
