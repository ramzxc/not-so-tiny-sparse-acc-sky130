// Unified TPU DMA with Multi-Row Burst Weight Cache Refill Support.
//
// Responsibilities:
//   * Demand-driven Multi-Row weight refill for Weight Cache
//   * DRAM -> unified buffer loads
//   * unified buffer -> DRAM stores
//   * accumulation buffer -> DRAM partial-result stores
//   * DRAM -> accumulation buffer partial-result restores
//   * Continuous byte-stream packing/unpacking across local-memory rows
//   * AXI-sized burst command and data generation
module dma
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH        = 4,
    parameter int DRAM_DATA_BYTES      = 8,
    parameter int MAX_BURST_BYTES      = 256,
    parameter int ROW_FIFO_DEPTH       = 8
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

    // -------------------------------------------------------------
    // Weight Cache <-> DMA Refill Port (Multi-Row Burst Support)
    // -------------------------------------------------------------
    input  logic                         cache_refill_req_valid,
    output logic                         cache_refill_req_ready,
    input  dram_addr_type                cache_refill_dram_addr,
    input  logic [7:0]                   cache_refill_len,      // [추가] Burst Row 길이 수신

    output fp16_type [COMPUTE_WIDTH-1:0] cache_refill_rsp_data,
    output logic                         cache_refill_rsp_valid,
    input  logic                         cache_refill_rsp_ready,

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

    localparam int ROW_BYTES = COMPUTE_WIDTH * FP16_BYTES;
    localparam int ROW_BITS  = ROW_BYTES * BYTE_WIDTH;
    localparam int MAX_BURST_BEATS = MAX_BURST_BYTES / DRAM_DATA_BYTES;

    localparam int OFFSET_WIDTH = (ROW_BYTES > 1) ? $clog2(ROW_BYTES) : 1;
    localparam int BEAT_OFFSET_WIDTH = (DRAM_DATA_BYTES > 1) ? $clog2(DRAM_DATA_BYTES) : 1;
    localparam int BEAT_COUNT_WIDTH = $clog2(DRAM_DATA_BYTES + 1);
    localparam int ROW_FIFO_PTR_WIDTH = (ROW_FIFO_DEPTH > 1) ? $clog2(ROW_FIFO_DEPTH) : 1;
    localparam int TRANSFER_COUNT_WIDTH = DRAM_ADDR_WIDTH + 1;

    typedef logic [OFFSET_WIDTH-1:0]        offset_type;
    typedef logic [BEAT_OFFSET_WIDTH-1:0]   beat_offset_type;
    typedef logic [BEAT_COUNT_WIDTH-1:0]    beat_byte_count_type;
    typedef logic [ROW_FIFO_PTR_WIDTH-1:0]  row_fifo_ptr_type;
    typedef logic [TRANSFER_COUNT_WIDTH-1:0] transfer_count_type;
    typedef logic [8:0]                     burst_beat_count_type;
    typedef logic [7:0]                     axi_len_type;
    typedef logic [ROW_BITS-1:0]            row_data_type;
    typedef logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] beat_data_type;

    typedef enum logic [1:0] {
        DMA_IDLE,
        DMA_LOAD,
        DMA_STORE,
        DMA_CACHE_REFILL
    } dma_state_type;

    function automatic row_fifo_ptr_type next_row_fifo_ptr(input row_fifo_ptr_type ptr);
        if (ptr == row_fifo_ptr_type'(ROW_FIFO_DEPTH - 1))
            next_row_fifo_ptr = '0;
        else
            next_row_fifo_ptr = ptr + 1'b1;
    endfunction

    function automatic transfer_count_type instruction_byte_count(input logic [LENGTH_WIDTH-1:0] length);
        longint unsigned byte_count;
    begin
        byte_count = $unsigned(length) * ROW_BYTES;
        instruction_byte_count = transfer_count_type'(byte_count);
    end
    endfunction

    function automatic transfer_count_type instruction_beat_count(input logic [LENGTH_WIDTH-1:0] length);
        longint unsigned byte_count;
        longint unsigned beat_count;
    begin
        byte_count = $unsigned(length) * ROW_BYTES;
        beat_count = (byte_count + DRAM_DATA_BYTES - 1) / DRAM_DATA_BYTES;
        instruction_beat_count = transfer_count_type'(beat_count);
    end
    endfunction

    function automatic burst_beat_count_type select_burst_beats(
        input dram_addr_type      address,
        input transfer_count_type beats_left
    );
        longint unsigned selected;
        longint unsigned boundary_bytes;
        longint unsigned boundary_beats;
    begin
        selected = $unsigned(beats_left);
        if (selected > MAX_BURST_BEATS)
            selected = MAX_BURST_BEATS;

        boundary_bytes = 4096 - ($unsigned(address) & 4095);
        boundary_beats = boundary_bytes / DRAM_DATA_BYTES;

        if ((boundary_beats != 0) && (selected > boundary_beats))
            selected = boundary_beats;

        select_burst_beats = burst_beat_count_type'(selected);
    end
    endfunction

    dma_state_type state_cs;
    memory_op_type operation_cs;

    // ------------------------------------------------------------------
    // Completed-row FIFO
    // ------------------------------------------------------------------
    row_data_type row_fifo_data [0:ROW_FIFO_DEPTH-1];
    logic [BUFFER_ADDR_WIDTH-1:0] row_fifo_local_addr [0:ROW_FIFO_DEPTH-1];

    row_fifo_ptr_type row_fifo_write_ptr_cs;
    row_fifo_ptr_type row_fifo_read_ptr_cs;
    row_fifo_ptr_type row_fifo_reserve_ptr_cs;

    logic row_fifo_empty;
    logic row_fifo_full;
    logic row_fifo_reserve_empty;
    logic row_fifo_reserve_full;
    logic row_fifo_can_push;
    logic row_fifo_can_reserve;
    logic row_fifo_push;
    logic row_fifo_pop;

    row_data_type                 row_fifo_push_data;
    logic [BUFFER_ADDR_WIDTH-1:0] row_fifo_push_local_addr;
    row_data_type                 row_fifo_head_data;
    logic [BUFFER_ADDR_WIDTH-1:0] row_fifo_head_local_addr;

    // ------------------------------------------------------------------
    // Load & Refill engine states
    // ------------------------------------------------------------------
    transfer_count_type      load_req_beats_left_cs;
    transfer_count_type      load_rsp_bytes_left_cs;
    logic [LENGTH_WIDTH-1:0] load_write_rows_left_cs;

    dram_addr_type                load_req_dram_addr_cs;
    logic [BUFFER_ADDR_WIDTH-1:0] load_rsp_local_addr_cs;
    offset_type                   load_rsp_offset_cs;

    row_data_type        load_rsp_row_data_cs;
    beat_data_type       load_beat_data_cs;
    beat_byte_count_type load_beat_bytes_left_cs;
    beat_offset_type     load_beat_offset_cs;
    logic                load_beat_valid_cs;

    row_data_type        load_unpack_row;
    beat_byte_count_type load_rsp_valid_byte_count;
    beat_byte_count_type load_unpack_byte_count;

    burst_beat_count_type load_cmd_beats;
    burst_beat_count_type load_rsp_burst_beats_left_cs;
    logic load_cmd_fire;
    logic load_rsp_fire;
    logic load_unpack_fire;
    logic load_unpack_completes_row;
    logic load_unpack_consumes_beat;
    logic load_row_complete;
    logic local_load_write_fire;

    // ------------------------------------------------------------------
    // Store engine states
    // ------------------------------------------------------------------
    logic [LENGTH_WIDTH-1:0]      store_local_req_rows_left_cs;
    logic [BUFFER_ADDR_WIDTH-1:0] store_local_req_addr_cs;

    transfer_count_type   store_cmd_beats_left_cs;
    transfer_count_type   store_stream_bytes_left_cs;
    dram_addr_type        store_cmd_addr_cs;
    offset_type           store_stream_row_offset_cs;
    burst_beat_count_type store_cmd_beats;
    burst_beat_count_type store_burst_beats_left_cs;
    logic                 store_burst_inflight_cs;

    row_data_type               packed_buffer_row;
    row_data_type               packed_acc_row;
    beat_data_type              store_beat_data_cs;
    logic [DRAM_DATA_BYTES-1:0] store_beat_strb_cs;
    beat_byte_count_type        store_beat_fill_cs;
    logic                       store_beat_valid_cs;

    beat_data_type              store_pack_data;
    logic [DRAM_DATA_BYTES-1:0] store_pack_strb;
    beat_byte_count_type        store_pack_byte_count;
    logic store_pack_fire;
    logic store_pack_completes_beat;
    logic store_pack_completes_stream;
    logic store_pack_consumes_row;
    logic local_store_req_fire;
    logic local_store_rsp_fire;
    logic store_cmd_fire;
    logic store_data_fire;
    logic store_rsp_fire;

    // Cache Refill 요청 처리
    logic accept_cache_refill;
    assign accept_cache_refill    = (state_cs == DMA_IDLE) && cache_refill_req_valid;
    assign cache_refill_req_ready = (state_cs == DMA_IDLE);

    logic accept_inst;
    assign accept_inst = (state_cs == DMA_IDLE) && inst_enable && !cache_refill_req_valid;

    assign busy = (state_cs != DMA_IDLE);

    assign weight_resource_busy = (state_cs == DMA_CACHE_REFILL);

    assign buffer_resource_busy =
        busy && ((operation_cs == mem_op_load_buffer) ||
                 (operation_cs == mem_op_store_buffer));

    assign acc_resource_busy =
        busy && ((operation_cs == mem_op_load_acc) ||
                 (operation_cs == mem_op_store_acc));

    // ------------------------------------------------------------------
    // FIFO Control
    // ------------------------------------------------------------------
    assign row_fifo_empty = (row_fifo_write_ptr_cs == row_fifo_read_ptr_cs);
    assign row_fifo_full  = (next_row_fifo_ptr(row_fifo_write_ptr_cs) == row_fifo_read_ptr_cs);

    assign row_fifo_reserve_empty = (row_fifo_reserve_ptr_cs == row_fifo_write_ptr_cs);
    assign row_fifo_reserve_full  = (next_row_fifo_ptr(row_fifo_reserve_ptr_cs) == row_fifo_read_ptr_cs);

    assign row_fifo_head_data       = row_fifo_data[row_fifo_read_ptr_cs];
    assign row_fifo_head_local_addr = row_fifo_local_addr[row_fifo_read_ptr_cs];

    assign row_fifo_pop =
        (((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) && local_load_write_fire) ||
        ((state_cs == DMA_STORE) && store_pack_fire && store_pack_consumes_row);

    assign row_fifo_can_push    = !row_fifo_full || row_fifo_pop;
    assign row_fifo_can_reserve = !row_fifo_reserve_full || row_fifo_pop;

    assign load_row_complete =
        ((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) &&
        load_unpack_fire && load_unpack_completes_row;

    assign row_fifo_push =
        load_row_complete ||
        ((state_cs == DMA_STORE) && local_store_rsp_fire);

    always_comb begin
        row_fifo_push_data       = '0;
        row_fifo_push_local_addr = '0;

        if ((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) begin
            row_fifo_push_data       = load_unpack_row;
            row_fifo_push_local_addr = load_rsp_local_addr_cs;
        end
        else if (state_cs == DMA_STORE) begin
            if (operation_cs == mem_op_store_buffer)
                row_fifo_push_data = packed_buffer_row;
            else
                row_fifo_push_data = packed_acc_row;
        end
    end

    // ------------------------------------------------------------------
    // Read Burst Command & Unpack (Shared between LOAD and CACHE_REFILL)
    // ------------------------------------------------------------------
    assign load_cmd_beats = select_burst_beats(load_req_dram_addr_cs, load_req_beats_left_cs);

    assign dram_read_cmd_addr  = load_req_dram_addr_cs;
    assign dram_read_cmd_len   = (load_cmd_beats == '0) ? 8'd0 : axi_len_type'(load_cmd_beats - 1'b1);
    assign dram_read_cmd_valid = ((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) &&
                                 (load_req_beats_left_cs != '0);
    assign load_cmd_fire       = dram_read_cmd_valid && dram_read_cmd_ready;

    assign dram_read_data_ready = ((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) &&
                                  (load_rsp_bytes_left_cs != '0) &&
                                  (!load_beat_valid_cs || (load_unpack_fire && load_unpack_consumes_beat));
    assign load_rsp_fire        = dram_read_data_valid && dram_read_data_ready;

    always_comb begin
        int unsigned selected;
        selected = DRAM_DATA_BYTES;
        if ($unsigned(load_rsp_bytes_left_cs) < selected)
            selected = $unsigned(load_rsp_bytes_left_cs);
        load_rsp_valid_byte_count = beat_byte_count_type'(selected);
    end

    always_comb begin
        int unsigned selected;
        int unsigned row_space;

        row_space = ROW_BYTES - $unsigned(load_rsp_offset_cs);
        selected = $unsigned(load_beat_bytes_left_cs);
        if (selected > row_space)
            selected = row_space;

        load_unpack_byte_count    = beat_byte_count_type'(selected);
        load_unpack_completes_row = (selected != 0) && (selected == row_space);
        load_unpack_consumes_beat = (selected != 0) && (selected == $unsigned(load_beat_bytes_left_cs));

        load_unpack_row = load_rsp_row_data_cs;
        for (int unsigned i = 0; i < ROW_BYTES; i++) begin
            if (i < selected) begin
                load_unpack_row[($unsigned(load_rsp_offset_cs)+i)*BYTE_WIDTH +: BYTE_WIDTH] =
                    load_beat_data_cs[($unsigned(load_beat_offset_cs)+i)*BYTE_WIDTH +: BYTE_WIDTH];
            end
        end
    end

    assign load_unpack_fire = ((state_cs == DMA_LOAD) || (state_cs == DMA_CACHE_REFILL)) &&
                              load_beat_valid_cs &&
                              (load_unpack_byte_count != '0) &&
                              (!load_unpack_completes_row || row_fifo_can_push);

    // ------------------------------------------------------------------
    // Local Outputs (Cache Refill, UB, ACC)
    // ------------------------------------------------------------------
    assign buffer_write_addr = buffer_addr_type'(row_fifo_head_local_addr);
    assign acc_write_addr    = accumulator_addr_type'(row_fifo_head_local_addr);

    always_comb begin
        buffer_write_data      = '0;
        acc_write_data         = '0;
        cache_refill_rsp_data  = '0;

        for (int lane = 0; lane < COMPUTE_WIDTH; lane++) begin
            for (int b = 0; b < FP16_BYTES; b++) begin
                buffer_write_data[lane][b*BYTE_WIDTH +: BYTE_WIDTH] =
                    row_fifo_head_data[(lane*FP16_BYTES+b)*BYTE_WIDTH +: BYTE_WIDTH];
                acc_write_data[lane][b*BYTE_WIDTH +: BYTE_WIDTH] =
                    row_fifo_head_data[(lane*FP16_BYTES+b)*BYTE_WIDTH +: BYTE_WIDTH];
                cache_refill_rsp_data[lane][b*BYTE_WIDTH +: BYTE_WIDTH] =
                    row_fifo_head_data[(lane*FP16_BYTES+b)*BYTE_WIDTH +: BYTE_WIDTH];
            end
        end
    end

    assign buffer_write_valid = (state_cs == DMA_LOAD) && !row_fifo_empty &&
                                (operation_cs == mem_op_load_buffer);

    assign acc_write_valid    = (state_cs == DMA_LOAD) && !row_fifo_empty &&
                                (operation_cs == mem_op_load_acc);

    assign cache_refill_rsp_valid = (state_cs == DMA_CACHE_REFILL) && !row_fifo_empty;

    always_comb begin
        case (state_cs)
            DMA_CACHE_REFILL:
                local_load_write_fire = cache_refill_rsp_valid && cache_refill_rsp_ready;
            DMA_LOAD: begin
                case (operation_cs)
                    mem_op_load_buffer: local_load_write_fire = buffer_write_valid && buffer_write_ready;
                    mem_op_load_acc:    local_load_write_fire = acc_write_valid && acc_write_ready;
                    default:            local_load_write_fire = 1'b0;
                endcase
            end
            default: local_load_write_fire = 1'b0;
        endcase
    end

    // ------------------------------------------------------------------
    // Local Store Channels
    // ------------------------------------------------------------------
    assign buffer_read_req_addr  = buffer_addr_type'(store_local_req_addr_cs);
    assign acc_read_req_addr     = accumulator_addr_type'(store_local_req_addr_cs);

    assign buffer_read_req_valid = (state_cs == DMA_STORE) &&
                                   (operation_cs == mem_op_store_buffer) &&
                                   (store_local_req_rows_left_cs != '0) &&
                                   row_fifo_can_reserve;

    assign acc_read_req_valid    = (state_cs == DMA_STORE) &&
                                   (operation_cs == mem_op_store_acc) &&
                                   (store_local_req_rows_left_cs != '0) &&
                                   row_fifo_can_reserve;

    assign local_store_req_fire  = (buffer_read_req_valid && buffer_read_req_ready) ||
                                   (acc_read_req_valid && acc_read_req_ready);

    assign buffer_read_rsp_ready = (state_cs == DMA_STORE) &&
                                   (operation_cs == mem_op_store_buffer) &&
                                   !row_fifo_reserve_empty && row_fifo_can_push;

    assign acc_read_rsp_ready    = (state_cs == DMA_STORE) &&
                                   (operation_cs == mem_op_store_acc) &&
                                   !row_fifo_reserve_empty && row_fifo_can_push;

    assign local_store_rsp_fire  = (buffer_read_rsp_valid && buffer_read_rsp_ready) ||
                                   (acc_read_rsp_valid && acc_read_rsp_ready);

    always_comb begin
        packed_buffer_row = '0;
        packed_acc_row    = '0;

        for (int lane = 0; lane < COMPUTE_WIDTH; lane++) begin
            for (int b = 0; b < FP16_BYTES; b++) begin
                packed_buffer_row[(lane*FP16_BYTES+b)*BYTE_WIDTH +: BYTE_WIDTH] =
                    buffer_read_rsp_data[lane][b*BYTE_WIDTH +: BYTE_WIDTH];
                packed_acc_row[(lane*FP16_BYTES+b)*BYTE_WIDTH +: BYTE_WIDTH] =
                    acc_read_rsp_data[lane][b*BYTE_WIDTH +: BYTE_WIDTH];
            end
        end
    end

    // ------------------------------------------------------------------
    // Store Engine Burst
    // ------------------------------------------------------------------
    assign store_cmd_beats      = select_burst_beats(store_cmd_addr_cs, store_cmd_beats_left_cs);
    assign dram_write_cmd_addr  = store_cmd_addr_cs;
    assign dram_write_cmd_len   = (store_cmd_beats == '0) ? 8'd0 : axi_len_type'(store_cmd_beats - 1'b1);
    assign dram_write_cmd_valid = (state_cs == DMA_STORE) && !store_burst_inflight_cs &&
                                  (store_cmd_beats_left_cs != '0);
    assign store_cmd_fire       = dram_write_cmd_valid && dram_write_cmd_ready;

    always_comb begin
        int unsigned beat_fill;
        int unsigned beat_space;
        int unsigned row_bytes_left;
        int unsigned selected;

        if (store_data_fire) begin
            store_pack_data = '0;
            store_pack_strb = '0;
            beat_fill       = 0;
        end
        else begin
            store_pack_data = store_beat_data_cs;
            store_pack_strb = store_beat_strb_cs;
            beat_fill       = $unsigned(store_beat_fill_cs);
        end

        beat_space     = DRAM_DATA_BYTES - beat_fill;
        row_bytes_left = ROW_BYTES - $unsigned(store_stream_row_offset_cs);

        selected = row_bytes_left;
        if (selected > beat_space)
            selected = beat_space;
        if (selected > $unsigned(store_stream_bytes_left_cs))
            selected = $unsigned(store_stream_bytes_left_cs);

        store_pack_byte_count       = beat_byte_count_type'(selected);
        store_pack_consumes_row     = (selected != 0) && (selected == row_bytes_left);
        store_pack_completes_beat   = (selected != 0) && ((beat_fill + selected) == DRAM_DATA_BYTES);
        store_pack_completes_stream = (selected != 0) && (selected == $unsigned(store_stream_bytes_left_cs));

        for (int unsigned i = 0; i < ROW_BYTES; i++) begin
            if (i < selected) begin
                store_pack_data[(beat_fill+i)*BYTE_WIDTH +: BYTE_WIDTH] =
                    row_fifo_head_data[($unsigned(store_stream_row_offset_cs)+i)*BYTE_WIDTH +: BYTE_WIDTH];
                store_pack_strb[beat_fill+i] = 1'b1;
            end
        end
    end

    assign store_pack_fire = (state_cs == DMA_STORE) &&
                             (store_stream_bytes_left_cs != '0) &&
                             !row_fifo_empty &&
                             (!store_beat_valid_cs || store_data_fire) &&
                             (store_pack_byte_count != '0);

    assign dram_write_data       = store_beat_data_cs;
    assign dram_write_strb       = store_beat_strb_cs;
    assign dram_write_data_valid = (state_cs == DMA_STORE) && store_burst_inflight_cs &&
                                   (store_burst_beats_left_cs != '0) && store_beat_valid_cs;
    assign dram_write_data_last  = (store_burst_beats_left_cs == 1);
    assign store_data_fire       = dram_write_data_valid && dram_write_data_ready;

    assign dram_write_rsp_ready  = (state_cs == DMA_STORE) && store_burst_inflight_cs &&
                                   (store_burst_beats_left_cs == '0);
    assign store_rsp_fire        = dram_write_rsp_valid && dram_write_rsp_ready;

    // ------------------------------------------------------------------
    // Main DMA FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_cs                     <= DMA_IDLE;
            operation_cs                 <= mem_op_none;

            load_req_beats_left_cs       <= '0;
            load_rsp_bytes_left_cs       <= '0;
            load_write_rows_left_cs      <= '0;
            load_req_dram_addr_cs        <= '0;
            load_rsp_local_addr_cs       <= '0;
            load_rsp_offset_cs           <= '0;
            load_rsp_row_data_cs         <= '0;
            load_beat_data_cs            <= '0;
            load_beat_bytes_left_cs      <= '0;
            load_beat_offset_cs          <= '0;
            load_beat_valid_cs           <= 1'b0;
            load_rsp_burst_beats_left_cs <= '0;

            store_local_req_rows_left_cs <= '0;
            store_local_req_addr_cs      <= '0;
            store_cmd_beats_left_cs      <= '0;
            store_stream_bytes_left_cs   <= '0;
            store_cmd_addr_cs            <= '0;
            store_stream_row_offset_cs   <= '0;
            store_burst_beats_left_cs    <= '0;
            store_burst_inflight_cs      <= 1'b0;
            store_beat_data_cs           <= '0;
            store_beat_strb_cs           <= '0;
            store_beat_fill_cs           <= '0;
            store_beat_valid_cs          <= 1'b0;

            row_fifo_write_ptr_cs        <= '0;
            row_fifo_read_ptr_cs         <= '0;
            row_fifo_reserve_ptr_cs      <= '0;
        end
        else begin
            case (state_cs)
                DMA_IDLE: begin
                    // 1) Weight Cache Refill 요청 처리 (Multi-Row Burst 적용)
                    if (accept_cache_refill) begin
                        state_cs                     <= DMA_CACHE_REFILL;
                        operation_cs                 <= mem_op_none;

                        // [수정] 요청된 cache_refill_len 크기만큼 Beat 및 Byte 계산
                        load_req_beats_left_cs       <= instruction_beat_count(cache_refill_len);
                        load_rsp_bytes_left_cs       <= instruction_byte_count(cache_refill_len);
                        load_write_rows_left_cs      <= cache_refill_len;
                        load_req_dram_addr_cs        <= cache_refill_dram_addr;
                        load_rsp_local_addr_cs       <= '0;
                        load_rsp_offset_cs           <= '0;
                        load_rsp_row_data_cs         <= '0;
                        load_beat_data_cs            <= '0;
                        load_beat_bytes_left_cs      <= '0;
                        load_beat_offset_cs          <= '0;
                        load_beat_valid_cs           <= 1'b0;
                        load_rsp_burst_beats_left_cs <= '0;

                        row_fifo_write_ptr_cs        <= '0;
                        row_fifo_read_ptr_cs         <= '0;
                        row_fifo_reserve_ptr_cs      <= '0;
                    end
                    // 2) 디코더 일반 메모리 명령어 처리 (UB, ACC)
                    else if (accept_inst) begin
                        operation_cs <= memory_op_type'(inst.opcode[2:0]);

                        load_req_beats_left_cs       <= instruction_beat_count(inst.length);
                        load_rsp_bytes_left_cs       <= instruction_byte_count(inst.length);
                        load_write_rows_left_cs      <= inst.length;
                        load_req_dram_addr_cs        <= inst.dram_addr;
                        load_rsp_local_addr_cs       <= inst.sram_addr;
                        load_rsp_offset_cs           <= '0;
                        load_rsp_row_data_cs         <= '0;
                        load_beat_data_cs            <= '0;
                        load_beat_bytes_left_cs      <= '0;
                        load_beat_offset_cs          <= '0;
                        load_beat_valid_cs           <= 1'b0;
                        load_rsp_burst_beats_left_cs <= '0;

                        store_local_req_rows_left_cs <= inst.length;
                        store_local_req_addr_cs      <= inst.sram_addr;
                        store_cmd_beats_left_cs      <= instruction_beat_count(inst.length);
                        store_stream_bytes_left_cs   <= instruction_byte_count(inst.length);
                        store_cmd_addr_cs            <= inst.dram_addr;
                        store_stream_row_offset_cs   <= '0;
                        store_burst_beats_left_cs    <= '0;
                        store_burst_inflight_cs      <= 1'b0;
                        store_beat_data_cs           <= '0;
                        store_beat_strb_cs           <= '0;
                        store_beat_fill_cs           <= '0;
                        store_beat_valid_cs          <= 1'b0;

                        row_fifo_write_ptr_cs        <= '0;
                        row_fifo_read_ptr_cs         <= '0;
                        row_fifo_reserve_ptr_cs      <= '0;

                        if (inst.length == '0) begin
                            state_cs     <= DMA_IDLE;
                            operation_cs <= mem_op_none;
                        end
                        else begin
                            case (memory_op_type'(inst.opcode[2:0]))
                                mem_op_load_buffer,
                                mem_op_load_acc:     state_cs <= DMA_LOAD;
                                mem_op_store_buffer,
                                mem_op_store_acc:    state_cs <= DMA_STORE;
                                default: begin
                                    state_cs     <= DMA_IDLE;
                                    operation_cs <= mem_op_none;
                                end
                            endcase
                        end
                    end
                end

                DMA_LOAD, DMA_CACHE_REFILL: begin
                    if (load_cmd_fire) begin
                        load_req_beats_left_cs       <= load_req_beats_left_cs - load_cmd_beats;
                        load_req_dram_addr_cs        <= load_req_dram_addr_cs +
                                                        dram_addr_type'($unsigned(load_cmd_beats) * DRAM_DATA_BYTES);
                        load_rsp_burst_beats_left_cs <= load_cmd_beats;
                    end

                    if (load_rsp_fire) begin
                        load_beat_data_cs            <= dram_read_data;
                        load_beat_bytes_left_cs      <= load_rsp_valid_byte_count;
                        load_beat_offset_cs          <= '0;
                        load_beat_valid_cs           <= 1'b1;

                        load_rsp_bytes_left_cs       <= load_rsp_bytes_left_cs - load_rsp_valid_byte_count;
                        load_rsp_burst_beats_left_cs <= load_rsp_burst_beats_left_cs - 1'b1;
                    end

                    if (load_unpack_fire) begin
                        if (load_unpack_completes_row) begin
                            row_fifo_data[row_fifo_write_ptr_cs]       <= load_unpack_row;
                            row_fifo_local_addr[row_fifo_write_ptr_cs] <= load_rsp_local_addr_cs;
                            row_fifo_write_ptr_cs                      <= next_row_fifo_ptr(row_fifo_write_ptr_cs);

                            load_rsp_row_data_cs   <= '0;
                            load_rsp_offset_cs     <= '0;
                            load_rsp_local_addr_cs <= load_rsp_local_addr_cs + 1'b1;
                        end
                        else begin
                            load_rsp_row_data_cs <= load_unpack_row;
                            load_rsp_offset_cs   <= offset_type'($unsigned(load_rsp_offset_cs) + $unsigned(load_unpack_byte_count));
                        end

                        if (!load_rsp_fire) begin
                            if (load_unpack_consumes_beat) begin
                                load_beat_bytes_left_cs <= '0;
                                load_beat_offset_cs     <= '0;
                                load_beat_valid_cs      <= 1'b0;
                            end
                            else begin
                                load_beat_bytes_left_cs <= load_beat_bytes_left_cs - load_unpack_byte_count;
                                load_beat_offset_cs     <= beat_offset_type'($unsigned(load_beat_offset_cs) + $unsigned(load_unpack_byte_count));
                            end
                        end
                    end

                    if (local_load_write_fire) begin
                        row_fifo_read_ptr_cs <= next_row_fifo_ptr(row_fifo_read_ptr_cs);

                        if (load_write_rows_left_cs == 1) begin
                            state_cs     <= DMA_IDLE;
                            operation_cs <= mem_op_none;
                        end
                        load_write_rows_left_cs <= load_write_rows_left_cs - 1'b1;
                    end
                end

                DMA_STORE: begin
                    if (local_store_req_fire) begin
                        store_local_req_rows_left_cs <= store_local_req_rows_left_cs - 1'b1;
                        store_local_req_addr_cs      <= store_local_req_addr_cs + 1'b1;
                        row_fifo_reserve_ptr_cs      <= next_row_fifo_ptr(row_fifo_reserve_ptr_cs);
                    end

                    if (local_store_rsp_fire) begin
                        row_fifo_data[row_fifo_write_ptr_cs]       <= row_fifo_push_data;
                        row_fifo_local_addr[row_fifo_write_ptr_cs] <= row_fifo_push_local_addr;
                        row_fifo_write_ptr_cs                      <= next_row_fifo_ptr(row_fifo_write_ptr_cs);
                    end

                    if (store_pack_fire) begin
                        store_beat_data_cs         <= store_pack_data;
                        store_beat_strb_cs         <= store_pack_strb;
                        store_stream_bytes_left_cs <= store_stream_bytes_left_cs - store_pack_byte_count;
                        store_beat_fill_cs         <= beat_byte_count_type'((store_data_fire ? 0 : $unsigned(store_beat_fill_cs)) +
                                                                            $unsigned(store_pack_byte_count));
                        store_beat_valid_cs        <= store_pack_completes_beat || store_pack_completes_stream;

                        if (store_pack_consumes_row)
                            store_stream_row_offset_cs <= '0;
                        else
                            store_stream_row_offset_cs <= offset_type'($unsigned(store_stream_row_offset_cs) + $unsigned(store_pack_byte_count));

                        if (store_pack_consumes_row)
                            row_fifo_read_ptr_cs <= next_row_fifo_ptr(row_fifo_read_ptr_cs);
                    end
                    else if (store_data_fire) begin
                        store_beat_data_cs  <= '0;
                        store_beat_strb_cs  <= '0;
                        store_beat_fill_cs  <= '0;
                        store_beat_valid_cs <= 1'b0;
                    end

                    if (store_cmd_fire) begin
                        store_cmd_beats_left_cs   <= store_cmd_beats_left_cs - store_cmd_beats;
                        store_cmd_addr_cs         <= store_cmd_addr_cs + dram_addr_type'($unsigned(store_cmd_beats) * DRAM_DATA_BYTES);
                        store_burst_beats_left_cs <= store_cmd_beats;
                        store_burst_inflight_cs   <= 1'b1;
                    end

                    if (store_data_fire) begin
                        store_burst_beats_left_cs <= store_burst_beats_left_cs - 1'b1;
                    end

                    if (store_rsp_fire) begin
                        store_burst_inflight_cs <= 1'b0;
                        if ((store_cmd_beats_left_cs == '0) && (store_stream_bytes_left_cs == '0)) begin
                            state_cs     <= DMA_IDLE;
                            operation_cs <= mem_op_none;
                        end
                    end
                end

                default: begin
                    state_cs     <= DMA_IDLE;
                    operation_cs <= mem_op_none;
                end
            endcase
        end
    end

endmodule
