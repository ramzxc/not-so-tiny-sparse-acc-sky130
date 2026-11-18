`default_nettype none
// Current RTL core. Only the internal 512 B SRAM is a hard macro.
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
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n)
    );
endmodule
`default_nettype wire
