`default_nettype none
// Hardened ICC2 core with internal 512 B SRAM.
module tt_um_not_so_tiny_sparse_acc_ramzxc (
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
    acc_hard_macro core (
`ifdef USE_POWER_PINS
        .VPWR(VPWR), .VGND(VGND),
`endif
        .uart_rx_i(ui_in[3]), .uo_out(uo_out),
        .qspi_dq_i({uio_in[5:4], uio_in[2:1]}),
        .uio_out(uio_out), .uio_oe(uio_oe), .clk(clk), .rst_n(rst_n)
    );
    wire _unused = &{ui_in[7:4], ui_in[2:0], uio_in[7:6], uio_in[3], uio_in[0], ena, 1'b0};
endmodule
`default_nettype wire
