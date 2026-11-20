`timescale 1ns/1ps
module tb_qspi_burst;
    logic clk, rst_n, req_val, req_write, req_continue, abort_read, stuck_busy;
    logic [23:0] req_addr;
    logic [7:0] req_data;
    wire req_rdy, read_data_val, sck, cs_n;
    wire [7:0] read_data;
    wire [3:0] dq_in, dq_out, dq_oe;
    wire [31:0] read_ops = flash.read_ops;
    qpi_engine dut (
        .clk(clk), .rst_n(rst_n), .req_val(req_val), .req_rdy(req_rdy),
        .req_write(req_write), .req_continue(req_continue), .abort_read(abort_read),
        .req_addr(req_addr), .req_device(2'b00), .req_data(req_data),
        .read_data(read_data), .read_data_val(read_data_val), .sck(sck),
        .flash_sc_n(cs_n), .psram_a_sc_n(), .psram_b_sc_n(),
        .dq_in(dq_in), .dq_out(dq_out), .dq_oe(dq_oe)
    );
    qspi_nor_model #(.BOARD_PREPARED(1)) flash (
        .clk(clk), .sck(sck), .cs_n(cs_n), .dq_out(dq_out), .dq_oe(dq_oe),
        .dq_in(dq_in), .stuck_busy(stuck_busy), .reject_wren(1'b0), .ignore_qe(1'b0)
    );
    initial begin
        #1;
        for (integer i=0; i<65536; i=i+1) flash.mem[i]=8'((i*37+11) ^ (i>>1));
    end
endmodule
