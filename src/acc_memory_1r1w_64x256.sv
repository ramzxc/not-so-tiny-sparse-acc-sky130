// 256-row logical memory, 32 or 64 bits wide, using one or two SKY130 SRAMs.
// The legacy module name is retained for existing build manifests.
// Port 0 is write-only; port 1 is read-only. The OpenRAM macro samples
// requests at posedge and updates memory/read data after negedge.
// Read data is consumed by the core at the following posedge.
module acc_memory_1r1w_64x256 #(parameter int DATA_WIDTH = 64) (
    input wire clk0, csb0,
    input wire [7:0] addr0,
    input wire [DATA_WIDTH-1:0] din0,
    input wire clk1, csb1,
    input wire [7:0] addr1,
    output wire [DATA_WIDTH-1:0] dout1
);
    wire [31:0] unused_read0;
    sky130_sram_1kbyte_1rw1r_32x256_8 bank0 (
        .clk0(clk0), .csb0(csb0), .web0(1'b0), .wmask0(4'b1111),
        .addr0(addr0), .din0(din0[31:0]), .dout0(unused_read0),
        .clk1(clk1), .csb1(csb1), .addr1(addr1), .dout1(dout1[31:0])
    );
    if (DATA_WIDTH == 64) begin : upper_bank
    wire [31:0] unused_read1;
    sky130_sram_1kbyte_1rw1r_32x256_8 bank1 (
        .clk0(clk0), .csb0(csb0), .web0(1'b0), .wmask0(4'b1111),
        .addr0(addr0), .din0(din0[63:32]), .dout0(unused_read1),
        .clk1(clk1), .csb1(csb1), .addr1(addr1), .dout1(dout1[63:32])
    );
    wire _unused_upper = &{unused_read1, 1'b0};
    end
`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH != 32 && DATA_WIDTH != 64)
            $fatal(1, "SRAM DATA_WIDTH must be 32 or 64");
    end
`endif
    // Physical vccd1/vssd1 pins are connected by PDN_MACRO_CONNECTIONS.
    wire _unused = &{unused_read0, 1'b0};
endmodule
