`timescale 1ns / 1ps

module kosmo2_layer_cfg_rom_v1_0 #(
    parameter [8*40-1:0] C_FILE = "../../mem/layer_cfg.mem"
)(
    input  wire [3:0]   layer,
    output wire [127:0] cfg
);

    reg [127:0] rom [0:9];

    initial begin
        $readmemh(C_FILE, rom);
    end

    assign cfg = rom[layer];

endmodule
