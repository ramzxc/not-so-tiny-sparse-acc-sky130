// Connect the same wrapper used by the gate test to the frozen core RTL.
module acc_hard_macro (
    input wire uart_rx_i,
    input wire [3:0] qspi_dq_i,
    output wire [7:0] uo_out, uio_out, uio_oe,
    input wire clk, rst_n
);
    acc_native_fp8_macro model (.*);
endmodule
