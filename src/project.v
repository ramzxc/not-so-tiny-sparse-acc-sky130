/* Copyright (c) 2024 Aram Yun
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none
module tt_um_not_so_tiny_sparse_acc_ramzxc (
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input wire ena, clk, rst_n
);
    wire rst = !rst_n || !ena;
    wire [5:0] address;
    wire [7:0] write_data, read_data, status;
    wire write_enable, action_enable, miso;
    acc_spi spi (
        .clk(clk), .rst(rst), .sck(ui_in[0]), .cs_n(ui_in[1]), .mosi(ui_in[2]),
        .miso(miso), .address(address), .write_data(write_data),
        .write_enable(write_enable), .action_enable(action_enable), .read_data(read_data)
    );
    acc_host host (
        .clk(clk), .rst(rst), .address(address), .write_data(write_data),
        .write_enable(write_enable), .action_enable(action_enable),
        .read_data(read_data), .status(status)
    );
    // MISO uses a bidirectional pin so it can be released while deselected.
    assign uio_out = {7'b0, miso};
    assign uio_oe = {7'b0, ena && rst_n && !ui_in[1]};
    assign uo_out = status;
    wire _unused = &{ui_in[7:3], uio_in, 1'b0};
endmodule
`default_nettype wire
