// 64 usable bits. OpenRAM's spare column is unused.
// Inputs are captured on rising clk; operation occurs on falling clk.
// No reset/initialization. One read OR write per cycle; csb/web active low.
module sram_64x128_1rw (
`ifdef USE_POWER_PINS
    inout vccd1, vssd1,
`endif
    input clk, csb, web,
    input [6:0] addr,
    input [63:0] din,
    output [63:0] dout
);
    wire [64:0] raw_dout;
    tt_sram_1rw_64x128_sky130 macro (
`ifdef USE_POWER_PINS
        .vccd1(vccd1), .vssd1(vssd1),
`endif
        .clk0(clk), .csb0(csb), .web0(web), .addr0(addr),
        .spare_wen0(1'b0), .din0({1'b0, din}), .dout0(raw_dout)
    );
    assign dout = raw_dout[63:0];
endmodule
