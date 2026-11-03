`timescale 1ns / 1ps

module kosmo2_async_fifo_v1_0 #(
    parameter integer C_W = 8,
    parameter integer C_D = 4
)(

    input  wire           wclk,
    input  wire           wrst_n,
    input  wire [C_W-1:0] wdata,
    input  wire           wvalid,
    output wire           wready,
    output wire           wfull,

    input  wire           rclk,
    input  wire           rrst_n,
    output wire [C_W-1:0] rdata,
    output wire           rvalid,
    input  wire           rready,
    output wire           rempty
);

    localparam integer PTR_W = C_D + 1;

    reg [C_W-1:0] mem [0:(1<<C_D)-1];
    reg [PTR_W-1:0] wbin, wgray;
    reg [PTR_W-1:0] rgray;
    reg [PTR_W-1:0] rq1_wgray, rq2_wgray;
    reg             wfull_r;

    wire wfire = wvalid & wready;
    wire [PTR_W-1:0] wbin_next  = wbin + {{(PTR_W-1){1'b0}}, wfire};
    wire [PTR_W-1:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    wire wfull_val = (wgray_next == {~rq2_wgray[PTR_W-1:PTR_W-2],
                                      rq2_wgray[PTR_W-3:0]});
    assign wfull  = wfull_r;
    assign wready = !wfull_r;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin       <= {PTR_W{1'b0}};
            wgray      <= {PTR_W{1'b0}};
            wfull_r    <= 1'b0;
            rq1_wgray  <= {PTR_W{1'b0}};
            rq2_wgray  <= {PTR_W{1'b0}};
        end else begin
            wfull_r <= wfull_val;
            if (wfire) begin
                mem[wbin[C_D-1:0]] <= wdata;
                wbin  <= wbin_next;
                wgray <= wgray_next;
            end
            rq1_wgray <= rgray;
            rq2_wgray <= rq1_wgray;
        end
    end

    reg [PTR_W-1:0] rbin;
    reg [PTR_W-1:0] wq1_wgray, wq2_wgray;

    wire rfire = rvalid & rready;
    wire [PTR_W-1:0] rbin_next  = rbin + {{(PTR_W-1){1'b0}}, rfire};
    wire [PTR_W-1:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    wire rempty_i = (rgray == wq2_wgray);
    assign rempty = rempty_i;
    assign rvalid = !rempty_i;
    assign rdata  = mem[rbin[C_D-1:0]];

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin       <= {PTR_W{1'b0}};
            rgray      <= {PTR_W{1'b0}};
            wq1_wgray  <= {PTR_W{1'b0}};
            wq2_wgray  <= {PTR_W{1'b0}};
        end else begin
            if (rfire) begin
                rbin  <= rbin_next;
                rgray <= rgray_next;
            end
            wq1_wgray <= wgray;
            wq2_wgray <= wq1_wgray;
        end
    end

endmodule
