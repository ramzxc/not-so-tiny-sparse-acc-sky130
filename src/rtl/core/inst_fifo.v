`include "../defs/defs.vh"

module inst_fifo # (
    parameter integer FIFO_DEPTH = 1
) (
    input  wire clk,
    input  wire rst_n,

    input  wire [`INST_WIDTH-1:0] inst_in,
    input  wire inst_in_val,

    output reg fifo_rdy,

    input  wire decoder_rdy,
    output reg [`INST_WIDTH-1:0] inst_out,
    output reg inst_out_val
);

    // All FIFO_DEPTH entries are usable. One host instruction per READY request.
    localparam integer PTR_BITS = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam integer COUNT_BITS = $clog2(FIFO_DEPTH + 1);

    reg [`INST_WIDTH-1:0] words [0:FIFO_DEPTH-1];
    reg [PTR_BITS-1:0] read_ptr;
    reg [PTR_BITS-1:0] write_ptr;
    reg [COUNT_BITS-1:0] count;

    wire pop = rst_n && (count != 0) && decoder_rdy;
    wire space_available = (count < COUNT_BITS'(FIFO_DEPTH));
    wire push = rst_n && inst_in_val && space_available;

    function [PTR_BITS-1:0] next_ptr;
        input [PTR_BITS-1:0] ptr;
        begin
            if (ptr == PTR_BITS'(FIFO_DEPTH - 1))
                next_ptr = 0;
            else
                next_ptr = ptr + 1'b1;
        end
    endfunction

    always @(*) begin
        // The core samples these on the same edge that advances read_ptr.
        inst_out = words[read_ptr];
        inst_out_val = rst_n && (count != 0);

        // Hold the request until RX returns an instruction. inst_in_val stays high
        // for one clock, giving TX a LOW request cycle before the next READY.
        // TX sends only once while fifo_rdy is continuously high.
        fifo_rdy = rst_n && space_available && !inst_in_val;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            read_ptr <= 0;
            write_ptr <= 0;
            count <= 0;
        end else begin
            if (push) begin
                words[write_ptr] <= inst_in;
                write_ptr <= next_ptr(write_ptr);
            end

            if (pop)
                read_ptr <= next_ptr(read_ptr);

            // Simultaneous receive and delivery keep the occupancy unchanged.
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: begin end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (FIFO_DEPTH < 1)
            $fatal(1, "FIFO_DEPTH must be at least one");
    end
`endif

endmodule
