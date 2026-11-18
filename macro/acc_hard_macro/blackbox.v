`default_nettype none
(* blackbox *) module acc_hard_macro (
`ifdef USE_POWER_PINS
    inout wire VPWR, VGND,
`endif
    input wire uart_rx_i,
    input wire [3:0] qspi_dq_i,
    output wire [7:0] uo_out, uio_out, uio_oe,
    input wire clk, rst_n
);
endmodule
`default_nettype wire
