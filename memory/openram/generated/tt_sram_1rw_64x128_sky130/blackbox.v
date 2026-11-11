(* blackbox *) module tt_sram_1rw_64x128_sky130 (
`ifdef USE_POWER_PINS
    inout vccd1, vssd1,
`endif
    input clk0, csb0, web0, spare_wen0,
    input [6:0] addr0,
    input [64:0] din0,
    output [64:0] dout0
);
endmodule
