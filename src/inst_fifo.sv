// Host instruction queue.
//
// The current FIFO head is presented to the decoder whenever the decoder can
// accept it. Instruction words remain 64 bits through inst_type.
module inst_fifo
    import tpu_pkg::*;
#(
    parameter int FIFO_DEPTH = 4
)(
    input logic clk,
    input logic rst,
    input inst_type word,
    input logic write_en,

    input logic core_busy,

    output inst_type data_out,

    output logic inst_pop,

    output logic empty,
    output logic full
);

    localparam FIFO_WIDTH = $bits(inst_type);

    logic pop;

    assign pop = !core_busy && !empty;
    assign inst_pop = pop;

    //fifo #(
    //    .FIFO_DEPTH(FIFO_DEPTH),
    //    .FIFO_WIDTH($bits(inst_type))
    //) fifo_0 (
    //    .clk(clk),
    //    .rst(rst),
    //    .data_in(word),
    //    .write_en(write_en),
    //    .data_out(data_out),
    //    .next_en(inst_pop),
    //    .empty(empty),
    //    .full(full)
    //);

    localparam int PTR_WIDTH =
        (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;

    typedef logic [PTR_WIDTH-1:0] fifo_ptr_t;

    logic [FIFO_WIDTH-1:0] ram [FIFO_DEPTH-1:0];

    fifo_ptr_t   read_ptr_cs;
    fifo_ptr_t   write_ptr_cs;

    logic push_fire;
    logic pop_fire;

    function automatic fifo_ptr_t next_ptr(input fifo_ptr_t ptr);
        if (ptr == fifo_ptr_t'(FIFO_DEPTH - 1))
            next_ptr = '0;
        else
            next_ptr = ptr + 1'b1;
    endfunction

    // Status is derived directly from the registered occupancy count.
    // There is no separately registered empty/full state.
    assign empty = (read_ptr_cs == write_ptr_cs);
    assign full  = (next_ptr(write_ptr_cs) == read_ptr_cs);

    // Keep the existing fall-through interface: data_out always presents
    // the current FIFO head without adding a read-latency cycle.
    assign data_out = empty ? '0 : ram[read_ptr_cs];

    assign pop_fire = pop && !empty;

    // A full FIFO may accept a write when a pop occurs on the same edge.
    assign push_fire = write_en && (!full || pop_fire);

`ifndef SYNTHESIS
    initial begin
        if (FIFO_DEPTH < 2)
            $fatal(1, "fifo FIFO_DEPTH must be at least two");
        if (FIFO_WIDTH < 1)
            $fatal(1, "fifo FIFO_WIDTH must be positive");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            read_ptr_cs  <= '0;
            write_ptr_cs <= '0;
        end
        else begin
            if (push_fire) begin
                ram[write_ptr_cs] <= word;
                write_ptr_cs      <= next_ptr(write_ptr_cs);
            end

            if (pop_fire)
                read_ptr_cs <= next_ptr(read_ptr_cs);
        end
    end

endmodule
