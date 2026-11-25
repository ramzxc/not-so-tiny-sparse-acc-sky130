// Unified TPU DMA with explicit weight-buffer preloads.
//
// Responsibilities:
//   * DRAM -> weight buffer loads
//   * DRAM -> unified buffer loads
//   * unified buffer -> DRAM stores
//   * accumulation buffer -> DRAM partial-result stores
//   * DRAM -> accumulation buffer partial-result restores
//   * accumulation buffer -> UART result words
//   * Continuous byte-stream packing/unpacking across local-memory rows
//   * Memory burst command and data generation
module dma
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH        = 2,
    parameter int DRAM_DATA_BYTES      = 8,
    parameter int MAX_BURST_BYTES      = 256,
    parameter int ROW_FIFO_DEPTH       = 2
)(
    input logic clk,
    input logic rst,

    // Instruction Decoder <-> DMA
    input dram_inst_type inst,
    input logic          inst_enable,

    output logic          busy,
    output logic          uart_range_error,

    // One external-memory command at a time, with directional data handshakes.
    output dram_addr_type                         dram_cmd_addr,
    output logic [7:0]                            dram_cmd_len,
    output logic                                  dram_cmd_write,
    output logic                                  dram_cmd_valid,
    input  logic                                  dram_cmd_ready,

    input  logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dram_rsp_data,
    input  logic                                  dram_rsp_valid,
    output logic                                  dram_rsp_ready,

    output logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dram_write_data,
    output logic [DRAM_DATA_BYTES-1:0]            dram_write_strb,
    output logic                                  dram_write_data_valid,
    input  logic                                  dram_write_data_ready,

    output logic [31:0]                           uart_result_data,
    output logic [2:0]                            uart_result_bytes,
    output logic                                  uart_result_valid,
    input  logic                                  uart_result_ready,

    // The region stays selected for the active instruction, including stalls.
    output sram_region_type                       sram_region,
    output buffer_addr_type                       sram_req_addr,
    output fp8_type [COMPUTE_WIDTH-1:0]            sram_req_data,
    output logic                                  sram_req_write,
    output logic                                  sram_req_valid,
    input  logic                                  sram_req_ready,
    input  fp8_type [COMPUTE_WIDTH-1:0]            sram_rsp_data,
    input  logic                                  sram_rsp_valid,
    output logic                                  sram_rsp_ready
);

    // This implementation targets two or four FP8 lanes and a 64-bit memory beat.
    // LOAD/STORE are mutually exclusive, so address/count/data registers share
    // storage. FIFO entries contain data only; local addresses advance on use.
    localparam int ROW_BITS = 8*COMPUTE_WIDTH;
    localparam int ROWS_PER_BEAT = DRAM_DATA_BYTES/COMPUTE_WIDTH;
    localparam int ROW_INDEX_WIDTH = $clog2(ROWS_PER_BEAT);
    localparam logic [7:0] ROW_STROBE = 8'((1 << COMPUTE_WIDTH) - 1);
    localparam int PTR_W = (ROW_FIFO_DEPTH > 1) ? $clog2(ROW_FIFO_DEPTH) : 1;
    localparam int MAX_BURST_BEATS = MAX_BURST_BYTES / 8;
    localparam int BURST_W = $clog2(MAX_BURST_BEATS + 1);
    typedef logic [PTR_W-1:0] ptr_t;
    typedef logic [BURST_W-1:0] burst_t;
    typedef enum logic [1:0] {DMA_IDLE, DMA_LOAD, DMA_STORE, DMA_UART} state_t;
    state_t state;

    logic [ROW_BITS-1:0] fifo [ROW_FIFO_DEPTH];
    ptr_t wr_ptr, rd_ptr, reserve_ptr;
    logic empty, full, reserved_empty, reserved_full;
    logic [ROW_BITS-1:0] fifo_head;

    dram_addr_type command_addr;
    buffer_addr_type local_addr;
    logic [7:0] command_beats_left; // ceil(rows / ROWS_PER_BEAT)
    logic [7:0] local_rows_left;    // LOAD writes or STORE read requests
    logic [7:0] stream_rows_left;   // LOAD unpack or STORE pack
    burst_t burst_left, command_beats;
    logic burst_active;
    logic [63:0] beat_data;
    logic beat_valid;
    logic [ROW_INDEX_WIDTH-1:0] row_index, pack_slot;
    logic [7:0] beat_strb;

    logic command_fire, read_fire, write_fire, response_fire;
    logic local_req_fire, load_write_fire, store_req_fire, store_rsp_fire;
    logic uart_result_fire;
    logic [2:0] inst_uart_bytes;
    logic [3:0] inst_uart_end_lane;
    logic unpack_fire, pack_fire, consume_load_beat;
    logic [ROW_BITS-1:0] unpack_row;

    function automatic ptr_t next_ptr(input ptr_t ptr);
        next_ptr = (ptr == PTR_W'(ROW_FIFO_DEPTH-1)) ? '0 : ptr + 1'b1;
    endfunction

    function automatic burst_t select_burst(input dram_addr_type address,
                                            input logic [7:0] remaining);
        logic [9:0] boundary_beats;
        logic [7:0] selected;
    begin
        // Keep DMA requests within 4 KiB. The controller may split them further.
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
    assign empty = wr_ptr == rd_ptr;
    assign full = next_ptr(wr_ptr) == rd_ptr;
    assign reserved_empty = reserve_ptr == wr_ptr;
    assign reserved_full = next_ptr(reserve_ptr) == rd_ptr;
    assign fifo_head = fifo[rd_ptr];

    assign command_beats = select_burst(command_addr,command_beats_left);
    assign dram_cmd_addr = command_addr;
    assign dram_cmd_len = command_beats == 0 ? 8'd0 : 8'(command_beats - 1'b1);
    assign dram_cmd_write = state == DMA_STORE;
    assign dram_cmd_valid = (state == DMA_LOAD || state == DMA_STORE) &&
                            !burst_active && command_beats_left != 0;
    assign command_fire = dram_cmd_valid && dram_cmd_ready;

    assign sram_req_addr = local_addr;
    assign sram_req_data = fifo_head;
    assign sram_req_write = state == DMA_LOAD;
    // No combinational ready -> valid path through the shared-memory arbiter.
    assign sram_req_valid = (state == DMA_LOAD && !empty) ||
                            (state == DMA_STORE && local_rows_left != 0 && !reserved_full) ||
                            (state == DMA_UART && local_rows_left != 0 && uart_result_ready);
    assign local_req_fire = sram_req_valid && sram_req_ready;
    assign load_write_fire = local_req_fire && sram_req_write;
    assign store_req_fire = local_req_fire && state == DMA_STORE;
    assign sram_rsp_ready = state == DMA_UART ? uart_result_ready :
                            (state == DMA_STORE && !reserved_empty && (!full || pack_fire));
    assign store_rsp_fire = sram_rsp_valid && sram_rsp_ready;

    // ACC_TO_UART reuses the low bits of the address register for its byte window.
    assign inst_uart_bytes = inst.dram_addr[2:0] == 0 ? 3'd2 : inst.dram_addr[2:0];
    assign inst_uart_end_lane = 4'(inst.dram_addr[4:3]) + 4'(inst_uart_bytes);
    assign uart_result_data = 32'(sram_rsp_data) >> {command_addr[4:3], 3'b000};
    assign uart_result_bytes = command_addr[2:0];
    assign uart_result_valid = state == DMA_UART && sram_rsp_valid;
    assign uart_result_fire = uart_result_valid && uart_result_ready;

    assign unpack_row = beat_data[row_index*ROW_BITS+:ROW_BITS];
    assign unpack_fire = state == DMA_LOAD && beat_valid && stream_rows_left != 0 &&
                         (!full || load_write_fire);
    assign consume_load_beat = unpack_fire && (row_index==ROW_INDEX_WIDTH'(ROWS_PER_BEAT-1) || stream_rows_left == 1);
    assign dram_rsp_ready = burst_active &&
        ((state == DMA_LOAD && burst_left != 0 && (!beat_valid || consume_load_beat)) ||
         (state == DMA_STORE && burst_left == 0));
    assign read_fire = state == DMA_LOAD && dram_rsp_valid && dram_rsp_ready;

    assign pack_fire = state == DMA_STORE && !empty && stream_rows_left != 0 &&
                       (!beat_valid || write_fire);
    assign pack_slot = write_fire ? '0 : row_index;
    assign dram_write_data = beat_data;
    assign dram_write_strb = beat_strb;
    assign dram_write_data_valid = state == DMA_STORE && burst_active && burst_left != 0 && beat_valid;
    assign write_fire = dram_write_data_valid && dram_write_data_ready;
    assign response_fire = state == DMA_STORE && dram_rsp_valid && dram_rsp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= DMA_IDLE;
            uart_range_error <= 1'b0;
            sram_region <= SRAM_REGION_UB;
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
            row_index <= 0;
            beat_strb <= 0;
        end else begin
            if (state == DMA_IDLE) begin
                if (inst_enable) begin
                    command_addr <= inst.dram_addr;
                    local_addr <= inst.sram_addr;
                    command_beats_left <= 8'(inst.length >> ROW_INDEX_WIDTH) + 8'(|inst.length[ROW_INDEX_WIDTH-1:0]);
                    local_rows_left <= inst.length;
                    stream_rows_left <= inst.length;
                    burst_left <= 0;
                    burst_active <= 0;
                    beat_data <= 0;
                    beat_valid <= 0;
                    row_index <= 0;
                    beat_strb <= 0;
                    wr_ptr <= 0;
                    rd_ptr <= 0;
                    reserve_ptr <= 0;
                    if (inst.length != 0) begin
                        case (memory_op_type'(inst.opcode[2:0]))
                            mem_op_load_buffer: begin
                                state <= DMA_LOAD;
                                sram_region <= SRAM_REGION_UB;
                            end
                            mem_op_load_weight: begin
                                state <= DMA_LOAD;
                                sram_region <= SRAM_REGION_WB;
                            end
                            mem_op_load_acc: begin
                                state <= DMA_LOAD;
                                sram_region <= SRAM_REGION_ACC;
                            end
                            mem_op_store_buffer: begin
                                state <= DMA_STORE;
                                sram_region <= SRAM_REGION_UB;
                            end
                            mem_op_store_acc: begin
                                state <= DMA_STORE;
                                sram_region <= SRAM_REGION_ACC;
                            end
                            mem_op_acc_to_uart: begin
                                if (inst_uart_end_lane <= 4'(COMPUTE_WIDTH)) begin
                                    state <= DMA_UART;
                                    sram_region <= SRAM_REGION_ACC;
                                    command_addr[2:0] <= inst_uart_bytes;
                                end else begin
                                    uart_range_error <= 1'b1;
                                end
                            end
                            default: ;
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
                if (local_req_fire) begin
                    local_addr <= local_addr + 1'b1;
                    local_rows_left <= local_rows_left - 1'b1;
                end
                if (unpack_fire || pack_fire) stream_rows_left <= stream_rows_left - 1'b1;
                if (state == DMA_LOAD) begin
                    if (unpack_fire) begin
                        fifo[wr_ptr] <= unpack_row;
                        wr_ptr <= next_ptr(wr_ptr);
                        row_index <= row_index+1'b1;
                        if (consume_load_beat) beat_valid <= 0;
                    end
                    // A newly accepted beat replaces the consumed beat on the same edge.
                    if (read_fire) begin
                        beat_data <= dram_rsp_data;
                        beat_valid <= 1;
                        row_index <= 0;
                        burst_left <= burst_left - 1'b1;
                        if (burst_left == 1) burst_active <= 0;
                    end
                    if (load_write_fire) begin
                        rd_ptr <= next_ptr(rd_ptr);
                        if (local_rows_left == 1) state <= DMA_IDLE;
                    end
                end else if (state == DMA_STORE) begin
                    if (store_req_fire) reserve_ptr <= next_ptr(reserve_ptr);
                    if (store_rsp_fire) begin fifo[wr_ptr] <= sram_rsp_data; wr_ptr <= next_ptr(wr_ptr); end
                    if (write_fire) begin
                        burst_left <= burst_left - 1'b1;
                        beat_valid <= 0;
                        row_index <= 0;
                        beat_data <= 0;
                        beat_strb <= 0;
                    end
                    if (pack_fire) begin
                        rd_ptr <= next_ptr(rd_ptr);
                        beat_data <= (pack_slot==0 ? 64'b0 : beat_data) |
                                     (64'(fifo_head)<<(pack_slot*ROW_BITS));
                        beat_strb <= (pack_slot==0 ? 8'b0 : beat_strb) | (ROW_STROBE<<(pack_slot*COMPUTE_WIDTH));
                        beat_valid <= pack_slot==ROW_INDEX_WIDTH'(ROWS_PER_BEAT-1) || stream_rows_left==1;
                        row_index <= pack_slot+1'b1;
                    end
                    if (response_fire) begin
                        burst_active <= 0;
                        if (command_beats_left == 0 && stream_rows_left == 0) begin
                            state <= DMA_IDLE;
                        end
                    end
                end else if (uart_result_fire) begin
                    stream_rows_left <= stream_rows_left - 1'b1;
                    if (stream_rows_left == 1) state <= DMA_IDLE;
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if ((COMPUTE_WIDTH != 2 && COMPUTE_WIDTH != 4) || DRAM_DATA_BYTES != 8 || LENGTH_WIDTH != 8)
            $fatal(1,"DMA requires two or four FP8 lanes, 64-bit beats and 8-bit length");
        if (ROW_FIFO_DEPTH < 2 || MAX_BURST_BYTES < 8 || MAX_BURST_BYTES > 2048 || MAX_BURST_BYTES % 8 != 0)
            $fatal(1,"Invalid DMA FIFO/burst parameters");
    end
    always @(posedge clk) begin
        if (!rst && state == DMA_IDLE && inst_enable && inst.length != 0 &&
            inst.opcode[2:0] != mem_op_acc_to_uart && inst.dram_addr[2:0] != 0)
            $error("DMA addresses must be 8-byte aligned");
    end
`endif
endmodule
