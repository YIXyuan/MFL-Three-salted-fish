//
// Generated (version 2025.2<build 211867>) at Tue Oct 20 20:00:07 2026
//

module AXI_wrapper
(
    input sys_clk,
    output led_busy,
    output led_done,
    output led_err,
    output led_bist_done,
    output led_bist_pass
);




    AXI AXI_inst_i (
            .sys_clk(sys_clk),
            .led_busy(led_busy),
            .led_done(led_done),
            .led_err(led_err),
            .led_bist_done(led_bist_done),
            .led_bist_pass(led_bist_pass));

endmodule
