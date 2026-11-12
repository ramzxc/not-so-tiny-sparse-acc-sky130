`default_nettype none
(* blackbox *) module acc_hard_macro (
`ifdef USE_POWER_PINS
    inout wire VPWR, VGND,
`endif
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input wire ena, clk, rst_n
);
endmodule
`default_nettype wire
