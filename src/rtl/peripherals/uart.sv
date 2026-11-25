// UART host port with PSRAM input slots and direct result output.
module uart #(
    parameter int INGRESS_BYTES = 2,
    parameter int SLOT_BITS = 2
) (
    input wire clk, rst_n, rx,
    output wire tx, fault,
    input wire [9:0] uart_clks_per_bit,
    input wire [8:0] input_bytes,
    input wire sync,
    output wire frame_ready,
    output wire [SLOT_BITS-1:0] frame_slot,
    output wire [SLOT_BITS:0] complete_frames,
    output wire [8:0] available_bytes,

    output logic input_valid,
    output logic [22:0] input_addr,
    output logic [8*INGRESS_BYTES-1:0] input_data,
    input wire input_ready, input_done,

    input wire result_valid,
    input wire [31:0] result_data,
    input wire [2:0] result_bytes,
    output wire result_ready
);
    localparam logic [22:0] INPUT_BASE = 23'h008000;
    wire [9:0] uart_bit_last = uart_clks_per_bit - 10'd1;
    logic [SLOT_BITS:0] produced, consumed;
    logic [8:0] byte_offset;
    logic [8*INGRESS_BYTES-1:0] packing;
    logic [8:0] committed_bytes;
    logic final_beat, inflight_final;
    logic queue_fault;
    wire [SLOT_BITS:0] pending_frames = produced - consumed;
    localparam logic [8:0] INGRESS_MASK = 9'(INGRESS_BYTES-1);
    wire [8:0] padded_bytes = (input_bytes + INGRESS_MASK) & ~INGRESS_MASK;
    wire [8:0] beat_offset = byte_offset & INGRESS_MASK;
    wire beat_complete = beat_offset == 9'(INGRESS_BYTES-2);
    wire [15:0] receive_word;
    wire received, receive_fault;
    wire [8*INGRESS_BYTES-1:0] next_beat_data;
    if (INGRESS_BYTES == 2) begin : pair_ingress
        assign next_beat_data = receive_word;
    end else begin : burst_ingress
        wire [63:0] packed_word = 64'(receive_word) << (beat_offset[2:1]*16);
        assign next_beat_data = beat_offset == 0 ? packed_word : packing | packed_word;
    end
    uart_rx uart_input (
        .clk(clk), .rst_n(rst_n), .data_out(receive_word), .data_valid(received),
        .error(receive_fault), .rx(rx),
        .bit_last(uart_bit_last), .half_bit_last((uart_clks_per_bit >> 1) - 10'd1)
    );

    assign available_bytes = pending_frames != 0 ? padded_bytes : committed_bytes;
    assign frame_ready = available_bytes != 0;
    assign frame_slot = consumed[SLOT_BITS-1:0];
    assign complete_frames = pending_frames;
    assign fault = receive_fault || queue_fault;

    // A queued complete slot is entirely readable. The producer also exposes
    // its committed prefix when it is the consumer's current slot.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            produced <= '0;
            consumed <= '0;
            byte_offset <= '0;
            committed_bytes <= '0;
            packing <= '0;
            queue_fault <= 0;
            input_valid <= 0;
            input_addr <= '0;
            input_data <= '0;
            final_beat <= 0;
            inflight_final <= 0;
        end else begin
            if (input_valid && input_ready) begin
                input_valid <= 0;
                inflight_final <= final_beat;
            end
            if (input_done) begin
                if (inflight_final) begin
                    produced <= produced + 1'b1;
                    committed_bytes <= 0;
                end else committed_bytes <= committed_bytes + 9'(INGRESS_BYTES);
            end
            if (sync) begin
                if (pending_frames == 0) queue_fault <= 1;
                consumed <= consumed + 1'b1;
            end
            if (received) begin
                if (pending_frames == ((SLOT_BITS+1)'(1)<<SLOT_BITS) ||
                    (beat_complete && input_valid && !input_ready)) begin
                    queue_fault <= 1;
                end else begin
                    packing <= next_beat_data;
                    byte_offset <= byte_offset + 9'd2;
                    if (beat_complete) begin
                        input_data <= next_beat_data;
                        input_addr <= INPUT_BASE + {{(15-SLOT_BITS){1'b0}},produced[SLOT_BITS-1:0],8'(byte_offset & ~INGRESS_MASK)};
                        input_valid <= 1;
                        final_beat <= byte_offset + 9'd2 == padded_bytes;
                    end
                    if (input_done && inflight_final) queue_fault <= 1;
                end
            end
            // Keep the slot and its trailing beat address until that beat
            // commits. At the selected baud it commits before the next word.
            if (input_done && inflight_final) byte_offset <= 0;
        end
    end

    uart_tx uart_output (
        .clk(clk), .rst_n(rst_n), .bit_last(uart_bit_last),
        .start(result_valid), .data_in(result_data), .byte_count(result_bytes),
        .tx(tx), .idle(result_ready)
    );
`ifndef SYNTHESIS
    initial if (INGRESS_BYTES != 2 && INGRESS_BYTES != 8) $fatal(1,"Unsupported ingress write size");
`endif
endmodule
