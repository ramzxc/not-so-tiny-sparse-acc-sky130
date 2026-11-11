/* Copyright (c) 2026 Aram Yun
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
    // ui[5:0]: word address; ui[6]: write; ui[7]: memory enable.
    // When disabled, shift eight input bytes MSB first into the write buffer.
    reg [63:0] write_buffer;
    always @(posedge clk) begin
        if (!rst_n)
            write_buffer <= 64'b0;
        else if (ena && !ui_in[7])
            write_buffer <= {write_buffer[55:0], uio_in};
    end

    wire [64:0] read_data;
    tt_sram_1rw_64x64_sky130 sram (
        .clk0(clk), .csb0(!(ena && rst_n && ui_in[7])),
        .web0(!ui_in[6]), .spare_wen0(1'b0), .addr0(ui_in[5:0]),
        .din0({1'b0, write_buffer}), .dout0(read_data)
    );
    // A read is sampled after the falling clock edge. Byte 0 is bits[7:0].
    assign uo_out = read_data[uio_in[2:0]*8 +: 8];
    assign uio_out = 8'b0;
    assign uio_oe = 8'b0;
    wire _unused = &{read_data[64], 1'b0};
endmodule
`default_nettype wire
