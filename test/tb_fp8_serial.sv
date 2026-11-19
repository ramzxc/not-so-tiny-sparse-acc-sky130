`timescale 1ns/1ps
module tb_fp8_serial #(parameter integer UART_CLKS_PER_BIT = 8);
    logic clk, rst_n, ena;
    logic [7:0] ui_in;
    wire [7:0] uo_out, uio_out, uio_oe;
    logic flash_stuck_busy, observe_upper;
    logic [15:0] flash_observe_addr;
    wire [15:0] flash_observe_data = {flash_model.mem[flash_observe_addr+1],
                                     flash_model.mem[flash_observe_addr]};
    wire [31:0] flash_read_ops = flash_model.read_ops;
    wire [8191:0] perf_sram_snapshot;
    wire [3:0] flash_dq;
`ifdef GL_TEST
    supply1 VPWR;
    supply0 VGND;
    // Observe the behavioral SRAM only; never initialize or force core state.
    for (genvar row=0; row<128; row=row+1) begin : observe_sram
        assign perf_sram_snapshot[64*row+:64] = dut.core.itf.memory.size_1k_macro.mem[row][63:0];
    end
    wire [63:0] perf_dma_cycles=0, perf_micro_cycles=0, perf_total_cycles=0;
    tt_um_not_so_tiny_sparse_acc_ramzxc dut (
        .VPWR(VPWR), .VGND(VGND),
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in),
        .uio_in({2'b00, flash_dq[3:2], 1'b0, flash_dq[1:0], 1'b0}),
        .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
    );
    defparam dut.core.itf.memory.size_1k_macro.VERBOSE = 0;
`else
    wire [15:0] mem_observe_data = dut.itf.read_data;
    for (genvar row=0; row<128; row=row+1) begin : observe_sram
        assign perf_sram_snapshot[64*row+:64] = dut.itf.memory.size_1k.macro.mem[row][63:0];
    end
    logic [63:0] perf_dma_cycles=0, perf_micro_cycles=0, perf_total_cycles=0;
    always @(posedge clk) begin
        perf_total_cycles <= perf_total_cycles+1;
        if (dut.dma_busy) perf_dma_cycles <= perf_dma_cycles+1;
        if (dut.micro_busy) perf_micro_cycles <= perf_micro_cycles+1;
    end
    acc_hard_macro #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx_i(ui_in[3]), .qspi_dq_i(flash_dq),
        .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
    );
    defparam dut.itf.memory.size_1k.macro.VERBOSE = 0;
`endif
    qspi_nor_model #(.BOARD_PREPARED(1)) flash_model (
        .clk(clk), .sck(uio_out[3]), .cs_n(uio_out[0]),
        .dq_out({uio_out[5:4],uio_out[2:1]}), .dq_oe({uio_oe[5:4],uio_oe[2:1]}),
        .dq_in(flash_dq), .stuck_busy(flash_stuck_busy), .reject_wren(1'b0), .ignore_qe(1'b0)
    );
    string fixture;
    initial begin
        #1;
        if (!$value$plusargs("FIXTURE=%s",fixture)) $fatal(1,"Missing FP8 Flash fixture");
        $readmemh(fixture,flash_model.mem);
    end
    always @(posedge clk) if (rst_n && uio_out[7:6] != 2'b11)
        $fatal(1,"PSRAM must remain deselected");
endmodule
