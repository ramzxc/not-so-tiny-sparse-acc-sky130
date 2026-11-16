// -----------------------------------------------------------------------------
// Ultra-Low Power 32-Way Weight Cache
// Conventions matched with weight_load_ctrl (Pipelined Dataflow, Fire Events)
// -----------------------------------------------------------------------------
module weight_cache
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH    = 4,
    parameter int MAX_COLUMN_ROWS  = COMPUTE_WIDTH,
    parameter int CACHE_LINES      = 128,
    parameter int WAY_COUNT        = 32,
    parameter int REQ_FIFO_DEPTH   = 8,
    parameter repl_policy_e POLICY = POLICY_DECAYED_LFU,

    localparam int SET_COUNT       = CACHE_LINES / WAY_COUNT,
    localparam int ROW_OFFSET_BITS = (MAX_COLUMN_ROWS > 1) ? $clog2(MAX_COLUMN_ROWS) : 0,
    localparam int SET_IDX_WIDTH   = (SET_COUNT > 1) ? $clog2(SET_COUNT) : 1,
    localparam int WAY_IDX_WIDTH   = $clog2(WAY_COUNT),
    localparam int TAG_WIDTH       = WEIGHT_ADDR_WIDTH - ROW_OFFSET_BITS - ((SET_COUNT > 1) ? SET_IDX_WIDTH : 0)
)(
    input  logic clk,
    input  logic rst,

    // Core <-> Cache Interface
    input  weight_addr_type              read_req_addr,
    input  logic [7:0]                   read_req_len,
    input  logic                         read_req_valid,
    output logic                         read_req_ready,

    output fp16_type [COMPUTE_WIDTH-1:0] read_rsp_data,
    output logic                         read_rsp_valid,

    // Cache <-> DMA Interface (Burst Refill)
    output logic                         dma_refill_req_valid,
    input  logic                         dma_refill_req_ready,
    output dram_addr_type                dma_refill_dram_addr,
    output logic [7:0]                   dma_refill_len,

    input  fp16_type [COMPUTE_WIDTH-1:0] dma_refill_rsp_data,
    input  logic                         dma_refill_rsp_valid
);

    localparam int FIFO_COUNT_WIDTH = $clog2(REQ_FIFO_DEPTH + 1);
    typedef logic [FIFO_COUNT_WIDTH-1:0] fifo_count_t;

    // =========================================================================
    // 1. Storage Arrays
    // =========================================================================
    logic [TAG_WIDTH-1:0]         tag_array   [SET_COUNT-1:0][WAY_COUNT-1:0];
    logic                         valid_array [SET_COUNT-1:0][WAY_COUNT-1:0];
    fp16_type [COMPUTE_WIDTH-1:0] data_array  [SET_COUNT-1:0][WAY_COUNT-1:0][MAX_COLUMN_ROWS-1:0];

    // =========================================================================
    // 2. Input Request FIFO (Stage 0)
    // =========================================================================
    typedef struct packed {
        weight_addr_type addr;
        logic [7:0]      len;
    } req_item_t;

    req_item_t fifo_mem [REQ_FIFO_DEPTH-1:0];
    fifo_count_t fifo_count_cs;
    logic [$clog2(REQ_FIFO_DEPTH)-1:0] fifo_wr_ptr_cs, fifo_rd_ptr_cs;

    logic fifo_full;
    logic fifo_empty;
    logic fifo_push_fire;
    logic fifo_pop_fire;

    assign fifo_full  = (fifo_count_cs == fifo_count_t'(REQ_FIFO_DEPTH));
    assign fifo_empty = (fifo_count_cs == '0);

    assign read_req_ready = !fifo_full;
    assign fifo_push_fire = read_req_valid && read_req_ready;

    // =========================================================================
    // 3. Serial Tag Scanner Engine (Stage 1: 1-Way / Cycle)
    // =========================================================================
    logic                       scanning_cs;
    logic [WAY_IDX_WIDTH-1:0]   scan_way_cs;
    req_item_t                  scan_req_cs;

    logic [TAG_WIDTH-1:0]       scan_tag;
    logic [SET_IDX_WIDTH-1:0]   scan_set;
    logic [ROW_OFFSET_BITS-1:0] scan_row_offset;

    logic                       hit_found_cs;
    logic [WAY_IDX_WIDTH-1:0]   hit_way_cs;
    logic                       empty_found_cs;
    logic [WAY_IDX_WIDTH-1:0]   empty_way_cs;

    generate
        if (ROW_OFFSET_BITS > 0) begin : gen_scan_offset
            assign scan_row_offset = scan_req_cs.addr[ROW_OFFSET_BITS-1:0];
        end else begin : gen_scan_no_offset
            assign scan_row_offset = '0;
        end

        if (SET_COUNT > 1) begin : gen_scan_set_addr
            assign scan_set = scan_req_cs.addr[ROW_OFFSET_BITS +: SET_IDX_WIDTH];
            assign scan_tag = scan_req_cs.addr[WEIGHT_ADDR_WIDTH-1 : ROW_OFFSET_BITS + SET_IDX_WIDTH];
        end else begin : gen_scan_fully_assoc
            assign scan_set = '0;
            assign scan_tag = scan_req_cs.addr[WEIGHT_ADDR_WIDTH-1 : ROW_OFFSET_BITS];
        end
    endgenerate

    // Replacement Policy Engine Interface
    logic [WAY_IDX_WIDTH-1:0] repl_victim_way;
    logic                     repl_update_valid;
    logic [SET_IDX_WIDTH-1:0] repl_update_set;
    logic [WAY_IDX_WIDTH-1:0] repl_update_way;
    logic                     repl_is_hit;

    cache_replacement_policy #(
        .POLICY        (POLICY),
        .SET_COUNT     (SET_COUNT),
        .WAY_COUNT     (WAY_COUNT)
    ) repl_engine (
        .clk           (clk),
        .rst           (rst),
        .access_valid  (repl_update_valid),
        .access_set    (repl_update_set),
        .access_way    (repl_update_way),
        .is_hit        (repl_is_hit),
        .query_set     (scan_set),
        .victim_way    (repl_victim_way)
    );

    logic                         refilling_cs;
    logic                         scan_end;
    logic                         curr_way_match;
    logic                         is_hit_overall;
    logic [WAY_IDX_WIDTH-1:0]     final_hit_way;
    logic [WAY_IDX_WIDTH-1:0]     final_target_way;

    logic                         scan_hit_fire;
    logic                         scan_miss_fire;

    fp16_type [COMPUTE_WIDTH-1:0] hit_rsp_data;
    logic                         hit_rsp_valid;

    assign scan_end        = scanning_cs && (scan_way_cs == WAY_IDX_WIDTH'(WAY_COUNT - 1));
    assign curr_way_match  = valid_array[scan_set][scan_way_cs] && (tag_array[scan_set][scan_way_cs] == scan_tag);
    assign is_hit_overall  = hit_found_cs || curr_way_match;
    assign final_hit_way   = hit_found_cs ? hit_way_cs : scan_way_cs;
    assign final_target_way = empty_found_cs ? empty_way_cs : 
                             (!valid_array[scan_set][scan_way_cs] ? scan_way_cs : repl_victim_way);

    assign fifo_pop_fire  = !scanning_cs && !fifo_empty;
    assign scan_hit_fire  = scan_end && is_hit_overall;
    assign scan_miss_fire = scan_end && !is_hit_overall && !refilling_cs;

    // =========================================================================
    // 4. Decoupled DMA Refill Engine (Stage 2)
    // =========================================================================
    req_item_t                  refill_req_cs;
    logic [SET_IDX_WIDTH-1:0]   refill_set_cs;
    logic [TAG_WIDTH-1:0]       refill_tag_cs;
    logic [ROW_OFFSET_BITS-1:0] refill_row_offset_cs;
    logic [WAY_IDX_WIDTH-1:0]   refill_way_cs;
    logic [7:0]                 refill_beat_cnt_cs;

    logic dma_req_fire;
    logic refill_beat_fire;
    logic refill_done_fire;

    fp16_type [COMPUTE_WIDTH-1:0] refill_rsp_data;
    logic                         refill_rsp_valid;

    assign dma_req_fire     = dma_refill_req_valid && dma_refill_req_ready;
    assign refill_beat_fire = refilling_cs && dma_refill_rsp_valid;
    assign refill_done_fire = refill_beat_fire && (refill_beat_cnt_cs == (refill_req_cs.len - 1'b1));

    dram_addr_type col_base_addr;
    generate
        if (ROW_OFFSET_BITS > 0) begin : gen_refill_col_base
            assign col_base_addr = dram_addr_type'({refill_req_cs.addr[WEIGHT_ADDR_WIDTH-1:ROW_OFFSET_BITS], {ROW_OFFSET_BITS{1'b0}}});
        end else begin : gen_refill_col_base_zero
            assign col_base_addr = refill_req_cs.addr;
        end
    endgenerate

    assign dma_refill_dram_addr = dram_addr_type'(col_base_addr * (COMPUTE_WIDTH * FP16_BYTES));
    assign dma_refill_len       = refill_req_cs.len;

    // =========================================================================
    // 5. Output Response Arbitration & Policy Updates
    // =========================================================================
    assign read_rsp_valid = hit_rsp_valid || refill_rsp_valid;
    assign read_rsp_data  = hit_rsp_valid ? hit_rsp_data : refill_rsp_data;

    assign repl_update_valid = hit_rsp_valid || refill_rsp_valid;
    assign repl_update_set   = hit_rsp_valid ? scan_set : refill_set_cs;
    assign repl_update_way   = hit_rsp_valid ? hit_way_cs : refill_way_cs;
    assign repl_is_hit       = hit_rsp_valid;

    // =========================================================================
    // Main Sequential Process
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_count_cs            <= '0;
            fifo_wr_ptr_cs           <= '0;
            fifo_rd_ptr_cs           <= '0;

            scanning_cs              <= 1'b0;
            scan_way_cs              <= '0;
            scan_req_cs              <= '0;
            hit_found_cs             <= 1'b0;
            hit_way_cs               <= '0;
            empty_found_cs           <= 1'b0;
            empty_way_cs             <= '0;

            hit_rsp_valid            <= 1'b0;
            hit_rsp_data             <= '0;

            refilling_cs             <= 1'b0;
            dma_refill_req_valid     <= 1'b0;
            refill_req_cs            <= '0;
            refill_set_cs            <= '0;
            refill_tag_cs            <= '0;
            refill_row_offset_cs     <= '0;
            refill_way_cs            <= '0;
            refill_beat_cnt_cs       <= '0;
            refill_rsp_valid         <= 1'b0;
            refill_rsp_data          <= '0;

            for (int s = 0; s < SET_COUNT; s++) begin
                for (int w = 0; w < WAY_COUNT; w++) begin
                    valid_array[s][w] <= 1'b0;
                    tag_array[s][w]   <= '0;
                end
            end
        end else begin
            // Pulse Clears
            hit_rsp_valid    <= 1'b0;
            refill_rsp_valid <= 1'b0;

            // FIFO Intake
            if (fifo_push_fire) begin
                fifo_mem[fifo_wr_ptr_cs].addr <= read_req_addr;
                fifo_mem[fifo_wr_ptr_cs].len  <= (read_req_len != '0) ? read_req_len : 8'd1;
                fifo_wr_ptr_cs <= (fifo_wr_ptr_cs == REQ_FIFO_DEPTH-1) ? '0 : fifo_wr_ptr_cs + 1'b1;
            end

            fifo_count_cs <= fifo_count_cs + fifo_push_fire - fifo_pop_fire;

            // Stage 1: Serial Tag Scanner
            if (fifo_pop_fire) begin
                scan_req_cs    <= fifo_mem[fifo_rd_ptr_cs];
                fifo_rd_ptr_cs <= (fifo_rd_ptr_cs == REQ_FIFO_DEPTH-1) ? '0 : fifo_rd_ptr_cs + 1'b1;
                scanning_cs    <= 1'b1;
                scan_way_cs    <= '0;
                hit_found_cs   <= 1'b0;
                empty_found_cs <= 1'b0;
            end else if (scanning_cs) begin
                if (curr_way_match) begin
                    hit_found_cs <= 1'b1;
                    hit_way_cs   <= scan_way_cs;
                end
                if (!valid_array[scan_set][scan_way_cs] && !empty_found_cs) begin
                    empty_found_cs <= 1'b1;
                    empty_way_cs   <= scan_way_cs;
                end

                if (scan_hit_fire) begin
                    hit_rsp_data  <= data_array[scan_set][final_hit_way][scan_row_offset];
                    hit_rsp_valid <= 1'b1;
                    scanning_cs   <= 1'b0;
                end else if (scan_miss_fire) begin
                    scanning_cs <= 1'b0; // 미스 전달 후 즉시 스캐너 해방
                end else if (!scan_end) begin
                    scan_way_cs <= scan_way_cs + 1'b1;
                end
            end

            // Stage 2: DMA Request & Stream Refill
            if (dma_req_fire) begin
                dma_refill_req_valid <= 1'b0;
            end

            if (scan_miss_fire) begin
                refilling_cs             <= 1'b1;
                dma_refill_req_valid     <= 1'b1;
                refill_req_cs            <= scan_req_cs;
                refill_set_cs            <= scan_set;
                refill_tag_cs            <= scan_tag;
                refill_row_offset_cs     <= scan_row_offset;
                refill_way_cs            <= final_target_way;
                refill_beat_cnt_cs       <= '0;
            end

            if (refill_beat_fire) begin
                data_array[refill_set_cs][refill_way_cs][refill_beat_cnt_cs] <= dma_refill_rsp_data;

                if (refill_beat_cnt_cs == 8'(refill_row_offset_cs)) begin
                    refill_rsp_data <= dma_refill_rsp_data;
                end

                if (refill_done_fire) begin
                    tag_array[refill_set_cs][refill_way_cs]   <= refill_tag_cs;
                    valid_array[refill_set_cs][refill_way_cs] <= 1'b1;
                    refill_rsp_valid                          <= 1'b1;
                    refilling_cs                              <= 1'b0;
                end else begin
                    refill_beat_cnt_cs <= refill_beat_cnt_cs + 1'b1;
                end
            end
        end
    end

endmodule
