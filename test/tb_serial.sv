`timescale 1ns/1ps
module tb_serial #(parameter integer UART_CLKS_PER_BIT = 8);
    logic clk, rst_n, ena;
    logic [7:0] ui_in;
    wire [7:0] uo_out, uio_in, uio_out, uio_oe;
    logic flash_stuck_busy;
    logic observe_upper;
    logic [15:0] flash_observe_addr;
    wire [31:0] flash_observe_data = {flash_model.mem[flash_observe_addr+3],
        flash_model.mem[flash_observe_addr+2],flash_model.mem[flash_observe_addr+1],flash_model.mem[flash_observe_addr]};
    wire [31:0] flash_read_ops = flash_model.read_ops;
    string perf_flash_file;
    initial begin
        #1;
        flash_model.mem[16'h0400] = 8'h00;
        flash_model.mem[16'h0401] = 8'h3c;
        flash_model.mem[16'h0402] = 8'h00;
        flash_model.mem[16'h0403] = 8'h00;
        flash_model.mem[16'h0404] = 8'h00;
        flash_model.mem[16'h0405] = 8'h40;
        flash_model.mem[16'h0406] = 8'h00;
        flash_model.mem[16'h0407] = 8'h44;
        flash_model.mem[16'h0408] = 8'h00;
        flash_model.mem[16'h0409] = 8'h00;
        flash_model.mem[16'h040a] = 8'h00;
        flash_model.mem[16'h040b] = 8'hc0;
        flash_model.mem[16'h040c] = 8'h00;
        flash_model.mem[16'h040d] = 8'h42;
        flash_model.mem[16'h040e] = 8'h00;
        flash_model.mem[16'h040f] = 8'h00;
        flash_model.mem[16'h0410] = 8'h00;
        flash_model.mem[16'h0411] = 8'h00;
        flash_model.mem[16'h0412] = 8'h00;
        flash_model.mem[16'h0413] = 8'h00;
        flash_model.mem[16'h0414] = 8'h00;
        flash_model.mem[16'h0415] = 8'h3c;
        flash_model.mem[16'h0416] = 8'h00;
        flash_model.mem[16'h0417] = 8'h00;
        flash_model.mem[16'h0500] = 8'h00;
        flash_model.mem[16'h0501] = 8'h3c;
        flash_model.mem[16'h0502] = 8'h00;
        flash_model.mem[16'h0503] = 8'h40;
        flash_model.mem[16'h0504] = 8'h00;
        flash_model.mem[16'h0505] = 8'h42;
        flash_model.mem[16'h0506] = 8'h00;
        flash_model.mem[16'h0507] = 8'h44;
        flash_model.mem[16'h0508] = 8'h00;
        flash_model.mem[16'h0509] = 8'h45;
        flash_model.mem[16'h050a] = 8'h00;
        flash_model.mem[16'h050b] = 8'h46;
        flash_model.mem[16'h050c] = 8'h00;
        flash_model.mem[16'h050d] = 8'h47;
        flash_model.mem[16'h050e] = 8'h00;
        flash_model.mem[16'h050f] = 8'h48;
        flash_model.mem[16'h0510] = 8'h80;
        flash_model.mem[16'h0511] = 8'h48;
        flash_model.mem[16'h0512] = 8'h00;
        flash_model.mem[16'h0513] = 8'h49;
        flash_model.mem[16'h0514] = 8'h80;
        flash_model.mem[16'h0515] = 8'h49;
        flash_model.mem[16'h0516] = 8'h00;
        flash_model.mem[16'h0517] = 8'h4a;
        // Four packed samples, three columns: [[0,1,0],[0,0,2],[0,-2,0],[0,0,3]].
        // Column 0 is all zero (including -0); columns 1/2 need one burst each.
        for (integer i=0; i<32; i=i+1) flash_model.mem[16'h0600+i] = 0;
        flash_model.mem[16'h0603] = 8'h3c;
        flash_model.mem[16'h0605] = 8'h80;
        flash_model.mem[16'h060b] = 8'hc0;
        flash_model.mem[16'h0615] = 8'h40;
        flash_model.mem[16'h061d] = 8'h42;
        // Performance fixtures: nonzero packed pairs and a zero initialization tile.
        for (integer i=0; i<32; i=i+1) begin
            {flash_model.mem[16'h0a00+4*i+3],flash_model.mem[16'h0a00+4*i+2],
             flash_model.mem[16'h0a00+4*i+1],flash_model.mem[16'h0a00+4*i]} = 32'h40003c00;
        end
        for (integer i=0; i<256; i=i+1) flash_model.mem[16'h0b00+i] = 0;
        // Arbitrary bits include signed zeros, subnormals, infinities and NaNs.
        for (integer i=0; i<512; i=i+1)
            flash_model.mem[16'h0800+i] = 8'((i*37+11) ^ (i>>1));
        {flash_model.mem[16'h0803],flash_model.mem[16'h0802],flash_model.mem[16'h0801],flash_model.mem[16'h0800]} = 32'h80000000;
        {flash_model.mem[16'h0807],flash_model.mem[16'h0806],flash_model.mem[16'h0805],flash_model.mem[16'h0804]} = 32'h7d017c00;
        {flash_model.mem[16'h080b],flash_model.mem[16'h080a],flash_model.mem[16'h0809],flash_model.mem[16'h0808]} = 32'hfc000001;
        // External Flash fixtures only, not hierarchical core/SRAM initialization.
        {flash_model.mem[3],flash_model.mem[2],flash_model.mem[1],flash_model.mem[0]} = 32'h40003c00;
        {flash_model.mem[7],flash_model.mem[6],flash_model.mem[5],flash_model.mem[4]} = 32'h44004200;
        {flash_model.mem[15],flash_model.mem[14],flash_model.mem[13],flash_model.mem[12]} = 32'h80000000;
        {flash_model.mem[19],flash_model.mem[18],flash_model.mem[17],flash_model.mem[16]} = 32'h00000100;
        {flash_model.mem[23],flash_model.mem[22],flash_model.mem[21],flash_model.mem[20]} = 32'h3c003c00;
        flash_model.mem[16'h0200] = 8'h00;
        flash_model.mem[16'h0201] = 8'h3c;
        flash_model.mem[16'h0202] = 8'h00;
        flash_model.mem[16'h0203] = 8'h40;
        flash_model.mem[16'h0204] = 8'h00;
        flash_model.mem[16'h0205] = 8'h00;
        flash_model.mem[16'h0206] = 8'h00;
        flash_model.mem[16'h0207] = 8'h42;
        flash_model.mem[16'h0208] = 8'h00;
        flash_model.mem[16'h0209] = 8'h80;
        flash_model.mem[16'h020a] = 8'h30;
        flash_model.mem[16'h020b] = 8'h56;
        flash_model.mem[16'h0300] = 8'h00;
        flash_model.mem[16'h0301] = 8'h3c;
        flash_model.mem[16'h0302] = 8'h00;
        flash_model.mem[16'h0303] = 8'h40;
        flash_model.mem[16'h0304] = 8'h00;
        flash_model.mem[16'h0305] = 8'h42;
        flash_model.mem[16'h0306] = 8'h00;
        flash_model.mem[16'h0307] = 8'h44;
        flash_model.mem[16'h0308] = 8'h00;
        flash_model.mem[16'h0309] = 8'h45;
        flash_model.mem[16'h030a] = 8'h00;
        flash_model.mem[16'h030b] = 8'h46;
        flash_model.mem[16'h030c] = 8'h00;
        flash_model.mem[16'h030d] = 8'h47;
        flash_model.mem[16'h030e] = 8'h00;
        flash_model.mem[16'h030f] = 8'h48;
        flash_model.mem[16'h0310] = 8'h00;
        flash_model.mem[16'h0311] = 8'h7e;
        flash_model.mem[16'h0312] = 8'h00;
        flash_model.mem[16'h0313] = 8'h7e;
        flash_model.mem[16'h0314] = 8'h00;
        flash_model.mem[16'h0315] = 8'h7e;
        flash_model.mem[16'h0316] = 8'h00;
        flash_model.mem[16'h0317] = 8'h7e;
        flash_model.mem[16'h0318] = 8'h80;
        flash_model.mem[16'h0319] = 8'h48;
        flash_model.mem[16'h031a] = 8'h00;
        flash_model.mem[16'h031b] = 8'h49;
        flash_model.mem[16'h031c] = 8'h80;
        flash_model.mem[16'h031d] = 8'h49;
        flash_model.mem[16'h031e] = 8'h00;
        flash_model.mem[16'h031f] = 8'h4a;
        flash_model.mem[16'h0320] = 8'h00;
        flash_model.mem[16'h0321] = 8'h7e;
        flash_model.mem[16'h0322] = 8'h00;
        flash_model.mem[16'h0323] = 8'h7e;
        flash_model.mem[16'h0324] = 8'h00;
        flash_model.mem[16'h0325] = 8'h7e;
        flash_model.mem[16'h0326] = 8'h00;
        flash_model.mem[16'h0327] = 8'h7e;
        // Optional external-memory stimulus for performance replay (not a core preload).
        if ($value$plusargs("perf_flash_file=%s", perf_flash_file))
            $readmemh(perf_flash_file, flash_model.mem);
    end
    wire [3:0] flash_dq;
`ifdef GL_TEST
    // Hold each valid SRAM response for the bit-exact DMA check. OpenRAM
    // invalidates dout0 on the next rising edge, long before UART SYNC returns.
    // Do not sample that idle X window or initialize the SRAM contents.
    reg [64:0] mem_observe_row;
    always @(negedge dut.\core.itf.memory.size_512.macro .clk0) begin
        if (!dut.\core.itf.memory.size_512.macro .csb0_reg &&
             dut.\core.itf.memory.size_512.macro .web0_reg) begin
            #(dut.\core.itf.memory.size_512.macro .DELAY + 1);
            mem_observe_row = dut.\core.itf.memory.size_512.macro .dout0;
        end
    end
    wire [31:0] mem_observe_data = observe_upper ? mem_observe_row[63:32] : mem_observe_row[31:0];
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
    tt_um_not_so_tiny_sparse_acc_ramzxc dut (
        .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe), .VPWR(VPWR), .VGND(VGND)
    );
`else
    // Cumulative counters for the optional throughput benchmark (testbench only).
    logic [63:0] perf_dma_cycles=0, perf_micro_cycles=0, perf_total_cycles=0;
    always @(posedge clk) begin
        perf_total_cycles <= perf_total_cycles + 1;
        if (dut.dma_busy) perf_dma_cycles <= perf_dma_cycles + 1;
        if (dut.micro_busy) perf_micro_cycles <= perf_micro_cycles + 1;
    end
    wire [31:0] mem_observe_data = dut.itf.read_data;
    // Read-only output snapshot: checking completion must not add UART waits.
    wire [4095:0] perf_sram_snapshot;
    for (genvar row=0; row<64; row=row+1) begin : perf_observe_sram
        assign perf_sram_snapshot[64*row+:64] = dut.itf.memory.size_512.macro.mem[row][63:0];
    end
    acc_hard_macro #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx_i(ui_in[3]),
        .qspi_dq_i({uio_in[5:4], uio_in[2:1]}),
        .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
    );
`endif
    assign uio_in = {2'b11, flash_dq[3:2], 1'b0, flash_dq[1:0], 1'b1};
    qspi_nor_model #(.BOARD_PREPARED(1)) flash_model (
        .clk(clk), .sck(uio_out[3]), .cs_n(uio_out[0]),
        .dq_out({uio_out[5:4],uio_out[2:1]}), .dq_oe({uio_oe[5:4],uio_oe[2:1]}),
        .dq_in(flash_dq), .stuck_busy(flash_stuck_busy), .reject_wren(1'b0), .ignore_qe(1'b0)
    );
    always @(posedge clk) begin
        if (rst_n && ((uio_oe[6] && !uio_out[6]) || (uio_oe[7] && !uio_out[7])))
            $fatal(1, "PSRAM must stay deselected");
    end
endmodule
