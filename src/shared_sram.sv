// Select exactly one generated OpenRAM 1RW macro. The 65th bit is a spare.
module shared_sram #(
    parameter int SRAM_BYTES = 512,
    parameter int ADDR_WIDTH = $clog2(SRAM_BYTES / 8)
)(
    input logic clk, enable, write,
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [63:0] wdata,
    output wire [63:0] rdata
);
    wire [64:0] raw_data;
    if (SRAM_BYTES == 1024) begin : size_1k
        tt_sram_1rw_64x128_sky130 macro (
            .clk0(clk), .csb0(!enable), .web0(!write),
            .spare_wen0(1'b0), .addr0(addr),
            .din0({1'b0,wdata}), .dout0(raw_data)
        );
    end else if (SRAM_BYTES == 512) begin : size_512
        tt_sram_1rw_64x64_sky130 macro (
            .clk0(clk), .csb0(!enable), .web0(!write),
            .spare_wen0(1'b0), .addr0(addr),
            .din0({1'b0,wdata}), .dout0(raw_data)
        );
    end
    // Isolate the characterized SRAM outputs from downstream mux/fanout load.
    // Keep the physical buffers through synthesis, but allow PnR resizing.
    // No registers or extra cycles are introduced; the spare bit is unused.
`ifdef SYNTHESIS
    for (genvar bit_idx=0; bit_idx<64; bit_idx++) begin : output_drive
        (* keep = 1 *) sky130_fd_sc_hd__buf_4 buffer_cell (
            .A(raw_data[bit_idx]), .X(rdata[bit_idx])
        );
    end
`else
    assign rdata = raw_data[63:0];
`endif
`ifndef SYNTHESIS
    initial if (SRAM_BYTES != 512 && SRAM_BYTES != 1024)
        $fatal(1, "shared_sram requires 512 or 1024 bytes");
`endif
endmodule
