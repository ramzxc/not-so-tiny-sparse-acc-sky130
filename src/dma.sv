// Unified TPU DMA with explicit weight-buffer preloads.
//
// Responsibilities:
//   * DRAM -> weight buffer loads
//   * DRAM -> unified buffer loads
//   * unified buffer -> DRAM stores
//   * accumulation buffer -> DRAM partial-result stores
//   * DRAM -> accumulation buffer partial-result restores
//   * Continuous byte-stream packing/unpacking across local-memory rows
//   * AXI-sized burst command and data generation
module dma
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH        = 2,
    parameter int DRAM_DATA_BYTES      = 8,
    parameter int MAX_BURST_BYTES      = 256,
    parameter int ROW_FIFO_DEPTH       = 4
)(
    input logic clk,
    input logic rst,

    // Instruction Decoder <-> DMA
    input dram_inst_type inst,
    input logic          inst_enable,

    output logic busy,
    output logic weight_resource_busy,
    output logic buffer_resource_busy,
    output logic acc_resource_busy,

    // Explicit DRAM -> weight-buffer preload (opcode 0x41).
    output weight_addr_type weight_write_addr,
    output fp16_type [COMPUTE_WIDTH-1:0] weight_write_data,
    output logic weight_write_valid,
    input logic weight_write_ready,

    // -------------------------------------------------------------
    // DRAM Read-burst command and returned data stream
    // -------------------------------------------------------------
    output dram_addr_type                         dram_read_cmd_addr,
    output logic [7:0]                            dram_read_cmd_len,
    output logic                                  dram_read_cmd_valid,
    input  logic                                  dram_read_cmd_ready,
    input  logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dram_read_data,
    input  logic                                  dram_read_data_last,
    input  logic                                  dram_read_data_valid,
    output logic                                  dram_read_data_ready,

    // -------------------------------------------------------------
    // DRAM Write-burst command, data stream, and completion response
    // -------------------------------------------------------------
    output dram_addr_type                         dram_write_cmd_addr,
    output logic [7:0]                            dram_write_cmd_len,
    output logic                                  dram_write_cmd_valid,
    input  logic                                  dram_write_cmd_ready,
    output logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dram_write_data,
    output logic [DRAM_DATA_BYTES-1:0]            dram_write_strb,
    output logic                                  dram_write_data_last,
    output logic                                  dram_write_data_valid,
    input  logic                                  dram_write_data_ready,
    input  logic                                  dram_write_rsp_valid,
    output logic                                  dram_write_rsp_ready,

    // -------------------------------------------------------------
    // Local Memory Paths (UB, ACC)
    // -------------------------------------------------------------
    // DRAM to unified buffer.
    output buffer_addr_type               buffer_write_addr,
    output fp16_type [COMPUTE_WIDTH-1:0]  buffer_write_data,
    output logic                          buffer_write_valid,
    input  logic                          buffer_write_ready,

    // Unified buffer to DRAM.
    output buffer_addr_type               buffer_read_req_addr,
    output logic                          buffer_read_req_valid,
    input  logic                          buffer_read_req_ready,
    input  fp16_type [COMPUTE_WIDTH-1:0]  buffer_read_rsp_data,
    input  logic                          buffer_read_rsp_valid,
    output logic                          buffer_read_rsp_ready,

    // Accumulator to DRAM.
    output accumulator_addr_type          acc_read_req_addr,
    output logic                          acc_read_req_valid,
    input  logic                          acc_read_req_ready,
    input  fp16_type [COMPUTE_WIDTH-1:0]  acc_read_rsp_data,
    input  logic                          acc_read_rsp_valid,
    output logic                          acc_read_rsp_ready,

    // DRAM to accumulator.
    output accumulator_addr_type          acc_write_addr,
    output fp16_type [COMPUTE_WIDTH-1:0]  acc_write_data,
    output logic                          acc_write_valid,
    input  logic                          acc_write_ready
);

    // This implementation targets two FP16 lanes and a 64-bit AXI beat.
    // LOAD/STORE are mutually exclusive, so address/count/data registers share
    // storage. FIFO entries contain data only; local addresses advance on use.
    localparam int PTR_W = (ROW_FIFO_DEPTH > 1) ? $clog2(ROW_FIFO_DEPTH) : 1;
    localparam int MAX_BURST_BEATS = MAX_BURST_BYTES / 8;
    localparam int BURST_W = $clog2(MAX_BURST_BEATS + 1);
    typedef logic [PTR_W-1:0] ptr_t;
    typedef logic [BURST_W-1:0] burst_t;
    typedef enum logic [1:0] {DMA_IDLE, DMA_LOAD, DMA_STORE} state_t;
    state_t state;
    memory_op_type operation;

    logic [31:0] fifo [ROW_FIFO_DEPTH];
    ptr_t wr_ptr, rd_ptr, reserve_ptr;
    logic empty, full, reserved_empty, reserved_full;
    logic [31:0] fifo_head;

    dram_addr_type command_addr;
    buffer_addr_type local_addr;
    logic [7:0] command_beats_left; // ceil(255 rows / 2) <= 128 beats
    logic [7:0] local_rows_left;    // LOAD writes or STORE read requests
    logic [7:0] stream_rows_left;   // LOAD unpack or STORE pack
    burst_t burst_left, command_beats;
    logic burst_active;
    logic [63:0] beat_data;
    logic beat_valid, half_word;
    logic [7:0] beat_strb;

    logic command_fire, read_fire, write_fire, response_fire;
    logic load_write_fire, store_req_fire, store_rsp_fire;
    logic unpack_fire, pack_fire, consume_load_beat, pack_has_low;
    logic [31:0] unpack_row, store_row;

    function automatic ptr_t next_ptr(input ptr_t ptr);
        next_ptr = (ptr == PTR_W'(ROW_FIFO_DEPTH-1)) ? '0 : ptr + 1'b1;
    endfunction

    function automatic burst_t select_burst(input dram_addr_type address,
                                            input logic [7:0] remaining);
        logic [9:0] boundary_beats;
        logic [7:0] selected;
    begin
        // Aligned 8-byte AXI beats: low 12 bits define the 4 KiB boundary.
        // 512 must be representable when the address is page-aligned.
        boundary_beats = 10'd512 - {1'b0,address[11:3]};
        selected = remaining;
        if (10'(selected) > 10'(MAX_BURST_BEATS))
            selected = 8'(MAX_BURST_BEATS);
        if (10'(selected) > boundary_beats)
            selected = 8'(boundary_beats);
        select_burst = BURST_W'(selected);
    end
    endfunction

    assign busy = state != DMA_IDLE;
    assign weight_resource_busy = state == DMA_LOAD && operation == mem_op_load_weight;
    assign buffer_resource_busy = busy && (operation == mem_op_load_buffer || operation == mem_op_store_buffer);
    assign acc_resource_busy = busy && (operation == mem_op_load_acc || operation == mem_op_store_acc);
    assign empty = wr_ptr == rd_ptr;
    assign full = next_ptr(wr_ptr) == rd_ptr;
    assign reserved_empty = reserve_ptr == wr_ptr;
    assign reserved_full = next_ptr(reserve_ptr) == rd_ptr;
    assign fifo_head = fifo[rd_ptr];

    assign command_beats = select_burst(command_addr,command_beats_left);
    assign dram_read_cmd_addr = command_addr;
    assign dram_write_cmd_addr = command_addr;
    assign dram_read_cmd_len = command_beats == 0 ? 8'd0 : 8'(command_beats - 1'b1);
    assign dram_write_cmd_len = dram_read_cmd_len;
    assign dram_read_cmd_valid = state == DMA_LOAD && !burst_active && command_beats_left != 0;
    assign dram_write_cmd_valid = state == DMA_STORE && !burst_active && command_beats_left != 0;
    assign command_fire = (dram_read_cmd_valid && dram_read_cmd_ready) ||
                          (dram_write_cmd_valid && dram_write_cmd_ready);

    assign weight_write_addr = weight_addr_type'(local_addr);
    assign buffer_write_addr = local_addr;
    assign acc_write_addr = accumulator_addr_type'(local_addr);
    assign weight_write_data = fifo_head;
    assign buffer_write_data = fifo_head;
    assign acc_write_data = fifo_head;
    assign weight_write_valid = state == DMA_LOAD && !empty && operation == mem_op_load_weight;
    assign buffer_write_valid = state == DMA_LOAD && !empty && operation == mem_op_load_buffer;
    assign acc_write_valid = state == DMA_LOAD && !empty && operation == mem_op_load_acc;
    assign load_write_fire = (weight_write_valid && weight_write_ready) ||
                             (buffer_write_valid && buffer_write_ready) ||
                             (acc_write_valid && acc_write_ready);
    assign unpack_row = half_word ? beat_data[63:32] : beat_data[31:0];
    assign unpack_fire = state == DMA_LOAD && beat_valid && stream_rows_left != 0 &&
                         (!full || load_write_fire);
    assign consume_load_beat = unpack_fire && (half_word || stream_rows_left == 1);
    assign dram_read_data_ready = state == DMA_LOAD && burst_active && burst_left != 0 &&
                                  (!beat_valid || consume_load_beat);
    assign read_fire = dram_read_data_valid && dram_read_data_ready;

    assign buffer_read_req_addr = local_addr;
    assign acc_read_req_addr = accumulator_addr_type'(local_addr);
    // No combinational ready -> valid path through the shared-memory arbiter.
    assign buffer_read_req_valid = state == DMA_STORE && operation == mem_op_store_buffer &&
                                   local_rows_left != 0 && !reserved_full;
    assign acc_read_req_valid = state == DMA_STORE && operation == mem_op_store_acc &&
                                local_rows_left != 0 && !reserved_full;
    assign store_req_fire = (buffer_read_req_valid && buffer_read_req_ready) ||
                            (acc_read_req_valid && acc_read_req_ready);
    assign buffer_read_rsp_ready = state == DMA_STORE && operation == mem_op_store_buffer &&
                                   !reserved_empty && (!full || pack_fire);
    assign acc_read_rsp_ready = state == DMA_STORE && operation == mem_op_store_acc &&
                                !reserved_empty && (!full || pack_fire);
    assign store_rsp_fire = (buffer_read_rsp_valid && buffer_read_rsp_ready) ||
                            (acc_read_rsp_valid && acc_read_rsp_ready);
    assign store_row = operation == mem_op_store_buffer ? buffer_read_rsp_data : acc_read_rsp_data;

    assign pack_fire = state == DMA_STORE && !empty && stream_rows_left != 0 &&
                       (!beat_valid || write_fire);
    assign pack_has_low = half_word && !write_fire;
    assign dram_write_data = beat_data;
    assign dram_write_strb = beat_strb;
    assign dram_write_data_valid = state == DMA_STORE && burst_active && burst_left != 0 && beat_valid;
    assign dram_write_data_last = burst_left == 1;
    assign write_fire = dram_write_data_valid && dram_write_data_ready;
    assign dram_write_rsp_ready = state == DMA_STORE && burst_active && burst_left == 0;
    assign response_fire = dram_write_rsp_valid && dram_write_rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= DMA_IDLE;
            operation <= mem_op_none;
            wr_ptr <= '0;
            rd_ptr <= '0;
            reserve_ptr <= '0;
            command_addr <= '0;
            local_addr <= '0;
            command_beats_left <= 0;
            local_rows_left <= 0;
            stream_rows_left <= 0;
            burst_left <= 0;
            burst_active <= 0;
            beat_data <= 0;
            beat_valid <= 0;
            half_word <= 0;
            beat_strb <= 0;
        end else begin
            if (state == DMA_IDLE) begin
                if (inst_enable) begin
                    operation <= memory_op_type'(inst.opcode[2:0]);
                    command_addr <= inst.dram_addr;
                    local_addr <= inst.sram_addr;
                    command_beats_left <= {1'b0,inst.length[7:1]} + {7'b0,inst.length[0]};
                    local_rows_left <= inst.length;
                    stream_rows_left <= inst.length;
                    burst_left <= 0;
                    burst_active <= 0;
                    beat_data <= 0;
                    beat_valid <= 0;
                    half_word <= 0;
                    beat_strb <= 0;
                    wr_ptr <= 0;
                    rd_ptr <= 0;
                    reserve_ptr <= 0;
                    if (inst.length != 0) begin
                        case (memory_op_type'(inst.opcode[2:0]))
                            mem_op_load_buffer, mem_op_load_weight, mem_op_load_acc: state <= DMA_LOAD;
                            mem_op_store_buffer, mem_op_store_acc: state <= DMA_STORE;
                            default: operation <= mem_op_none;
                        endcase
                    end
                end
            end else begin
                if (command_fire) begin
                    command_addr <= command_addr + (dram_addr_type'(command_beats) << 3);
                    command_beats_left <= command_beats_left - 8'(command_beats);
                    burst_left <= command_beats;
                    burst_active <= 1;
                end
                if (load_write_fire || store_req_fire) begin
                    local_addr <= local_addr + 1'b1;
                    local_rows_left <= local_rows_left - 1'b1;
                end
                if (unpack_fire || pack_fire) stream_rows_left <= stream_rows_left - 1'b1;
                if (state == DMA_LOAD) begin
                    if (unpack_fire) begin
                        fifo[wr_ptr] <= unpack_row;
                        wr_ptr <= next_ptr(wr_ptr);
                        half_word <= !half_word;
                        if (consume_load_beat) beat_valid <= 0;
                    end
                    // A newly accepted beat replaces the consumed beat on the same edge.
                    if (read_fire) begin
                        beat_data <= dram_read_data;
                        beat_valid <= 1;
                        half_word <= 0;
                        burst_left <= burst_left - 1'b1;
                        if (burst_left == 1) burst_active <= 0;
                    end
                    if (load_write_fire) begin
                        rd_ptr <= next_ptr(rd_ptr);
                        if (local_rows_left == 1) begin state <= DMA_IDLE; operation <= mem_op_none; end
                    end
                end else begin
                    if (store_req_fire) reserve_ptr <= next_ptr(reserve_ptr);
                    if (store_rsp_fire) begin fifo[wr_ptr] <= store_row; wr_ptr <= next_ptr(wr_ptr); end
                    if (write_fire) begin
                        burst_left <= burst_left - 1'b1;
                        beat_valid <= 0;
                        half_word <= 0;
                        beat_data <= 0;
                        beat_strb <= 0;
                    end
                    if (pack_fire) begin
                        rd_ptr <= next_ptr(rd_ptr);
                        beat_data <= pack_has_low ? {fifo_head,beat_data[31:0]} : {32'b0,fifo_head};
                        beat_strb <= pack_has_low ? 8'hff : 8'h0f;
                        beat_valid <= pack_has_low || stream_rows_left == 1;
                        half_word <= !pack_has_low;
                    end
                    if (response_fire) begin
                        burst_active <= 0;
                        if (command_beats_left == 0 && stream_rows_left == 0) begin
                            state <= DMA_IDLE;
                            operation <= mem_op_none;
                        end
                    end
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (COMPUTE_WIDTH != 2 || DRAM_DATA_BYTES != 8 || LENGTH_WIDTH != 8)
            $fatal(1,"DMA requires two FP16 lanes, 64-bit AXI and 8-bit length");
        if (ROW_FIFO_DEPTH < 2 || MAX_BURST_BYTES < 8 || MAX_BURST_BYTES > 2048 || MAX_BURST_BYTES % 8)
            $fatal(1,"Invalid DMA FIFO/burst parameters");
    end
    always @(posedge clk) begin
        if (!rst && state == DMA_IDLE && inst_enable && inst.length != 0 && inst.dram_addr[2:0] != 0)
            $error("DMA AXI addresses must be 8-byte aligned");
        if (!rst && read_fire && dram_read_data_last != (burst_left == 1))
            $error("DMA read LAST mismatch");
    end
`endif
endmodule
