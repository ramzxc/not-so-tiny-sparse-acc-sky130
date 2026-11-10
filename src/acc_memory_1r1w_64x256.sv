// Portable memory for the SKY130 standard-cell flow. No process macro required.
// Synchronous read, old-data read-during-write, one-cycle response.
module acc_memory_1r1w_64x256 (
    input wire clk0, csb0,
    input wire [7:0] addr0,
    input wire [63:0] din0,
    input wire clk1, csb1,
    input wire [7:0] addr1,
    output reg [63:0] dout1
);
    reg [63:0] mem [0:255];
    always @(posedge clk0)
        if (!csb0) mem[addr0] <= din0;
    always @(posedge clk1)
        if (!csb1) dout1 <= mem[addr1];
endmodule
