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
    assign rdata = raw_data[63:0];
`ifndef SYNTHESIS
    initial if (SRAM_BYTES != 512 && SRAM_BYTES != 1024)
        $fatal(1, "shared_sram requires 512 or 1024 bytes");
`endif
endmodule
