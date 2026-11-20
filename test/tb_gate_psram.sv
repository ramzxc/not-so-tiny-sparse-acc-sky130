`timescale 1ns/1ps
module tb_gate_psram;
    reg clk, rst_n, ena;
    reg [7:0] ui_in;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire [3:0] dq;
    supply1 VPWR;
    supply0 VGND;
    tt_um_not_so_tiny_sparse_acc_ramzxc dut (
        .VPWR(VPWR), .VGND(VGND), .clk(clk), .rst_n(rst_n), .ena(ena),
        .ui_in(ui_in), .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe),
        .uio_in({2'b00, dq[3:2], 1'b0, dq[1:0], 1'b0}));
    // Explicit ns value avoids Icarus 11 time-literal parameter scaling.
    qspi_psram_model #(.MAX_CS_LOW(8000)) psram_model (
        .sck(uio_oe[3] ? uio_out[3] : 1'b0),
        .cs_n(uio_oe[6] ? uio_out[6] : 1'b1),
        .dq_out({uio_out[5:4], uio_out[2:1]}),
        .dq_oe({uio_oe[5:4], uio_oe[2:1]}), .dq_in(dq));
    reg [22:0] observe_addr;
    wire [15:0] observe_data = {psram_model.mem[observe_addr+1], psram_model.mem[observe_addr]};
    wire [31:0] reads = psram_model.reads, writes = psram_model.writes;
    string fixture;
    initial begin
        #1;
        if (!$value$plusargs("FIXTURE=%s", fixture)) $fatal(1, "missing PSRAM image");
        $readmemh(fixture, psram_model.mem);
    end
endmodule
