// -----------------------------------------------------------------------------
// 32-Way Scalable Replacement Policy Engine for BCI (Including Custom Hybrid Policy)
// -----------------------------------------------------------------------------
module cache_replacement_policy
    import tpu_pkg::*;
#(
    parameter repl_policy_e POLICY   = POLICY_DECAYED_LFU,
    parameter int SET_COUNT          = 4,
    parameter int WAY_COUNT          = 32,
    parameter int LFU_CTR_WIDTH      = 8,
    parameter int DECAY_PERIOD       = 256,
    parameter int PROBATION_WAYS     = 8,   // Way 0 ~ 7: Probationary, Way 8 ~ 31: Protected
    parameter int SET_IDX_WIDTH      = (SET_COUNT > 1) ? $clog2(SET_COUNT) : 1,
    parameter int WAY_IDX_WIDTH      = $clog2(WAY_COUNT)
)(
    input  logic clk,
    input  logic rst,

    input  logic                     access_valid,
    input  logic [SET_IDX_WIDTH-1:0] access_set,
    input  logic [WAY_IDX_WIDTH-1:0] access_way,
    input  logic                     is_hit,

    input  logic [SET_IDX_WIDTH-1:0] query_set,
    output logic [WAY_IDX_WIDTH-1:0] victim_way
);

    generate
        // =====================================================================
        // 1. Decayed LFU
        // =====================================================================
        if (POLICY == POLICY_DECAYED_LFU) begin : gen_decayed_lfu
            logic [LFU_CTR_WIDTH-1:0] freq_cnt [SET_COUNT-1:0][WAY_COUNT-1:0];
            logic [$clog2(DECAY_PERIOD)-1:0] decay_timer_cs;
            logic decay_trigger;

            assign decay_trigger = (decay_timer_cs == (DECAY_PERIOD - 1));

            always_comb begin
                logic [LFU_CTR_WIDTH-1:0] min_val;
                victim_way = '0;
                min_val    = freq_cnt[query_set][0];

                for (int w = 1; w < WAY_COUNT; w++) begin
                    if (freq_cnt[query_set][w] < min_val) begin
                        min_val    = freq_cnt[query_set][w];
                        victim_way = WAY_IDX_WIDTH'(w);
                    end
                end
            end

            always_ff @(posedge clk) begin
                if (rst) begin
                    decay_timer_cs <= '0;
                    for (int s = 0; s < SET_COUNT; s++) begin
                        for (int w = 0; w < WAY_COUNT; w++) begin
                            freq_cnt[s][w] <= '0;
                        end
                    end
                end else begin
                    if (decay_trigger) decay_timer_cs <= '0;
                    else               decay_timer_cs <= decay_timer_cs + 1'b1;

                    if (decay_trigger) begin
                        for (int s = 0; s < SET_COUNT; s++) begin
                            for (int w = 0; w < WAY_COUNT; w++) begin
                                freq_cnt[s][w] <= freq_cnt[s][w] >> 1;
                            end
                        end
                    end

                    if (access_valid) begin
                        if (is_hit) begin
                            if (freq_cnt[access_set][access_way] != {LFU_CTR_WIDTH{1'b1}}) begin
                                freq_cnt[access_set][access_way] <= freq_cnt[access_set][access_way] + 1'b1;
                            end
                        end else begin
                            freq_cnt[access_set][access_way] <= {{LFU_CTR_WIDTH-1{1'b0}}, 1'b1};
                        end
                    end
                end
            end
        end

        // =====================================================================
        // 2. Segmented LRU (SLRU: Fixed Way Partitioning)
        // =====================================================================
        else if (POLICY == POLICY_SLRU) begin : gen_slru
            localparam int PROT_WAYS = WAY_COUNT - PROBATION_WAYS;
            logic [$clog2(PROBATION_WAYS)-1:0] prob_fifo [SET_COUNT-1:0];

            assign victim_way = WAY_IDX_WIDTH'(prob_fifo[query_set]);

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (int s = 0; s < SET_COUNT; s++) prob_fifo[s] <= '0;
                end else if (access_valid && !is_hit) begin
                    if (prob_fifo[access_set] == PROBATION_WAYS - 1)
                        prob_fifo[access_set] <= '0;
                    else
                        prob_fifo[access_set] <= prob_fifo[access_set] + 1'b1;
                end
            end
        end

        // =====================================================================
        // 3. Custom Hybrid Policy (Transplanted from C++ CustomCache)
        // =====================================================================
        else if (POLICY == POLICY_CUSTOM) begin : gen_custom
            // C++의 frequency(빈도)와 score(중요도 점수) 개념을 하드웨어 레지스터로 매핑
            logic [7:0] custom_freq  [SET_COUNT-1:0][WAY_COUNT-1:0];
            logic [7:0] custom_score [SET_COUNT-1:0][WAY_COUNT-1:0];
            logic [11:0] decay_timer_cs;
            logic decay_trigger;

            assign decay_trigger = (decay_timer_cs == 4095);

            // Hybrid Score 조합 논리: Score와 Freq를 결합하여 가장 값이 작은 Way를 Victim으로 선정
            always_comb begin
                automatic int min_hybrid_val;
                victim_way = '0;
                min_hybrid_val = (custom_freq[query_set][0] * 50) + (custom_score[query_set][0] * 50);

                for (int w = 1; w < WAY_COUNT; w++) begin
                    automatic int h_val = (custom_freq[query_set][w] * 50) + (custom_score[query_set][w] * 50);
                    if (h_val < min_hybrid_val) begin
                        min_hybrid_val = h_val;
                        victim_way     = WAY_IDX_WIDTH'(w);
                    end
                end
            end

            always_ff @(posedge clk) begin
                if (rst) begin
                    decay_timer_cs <= '0;
                    for (int s = 0; s < SET_COUNT; s++) begin
                        for (int w = 0; w < WAY_COUNT; w++) begin
                            custom_freq[s][w]  <= '0;
                            custom_score[s][w] <= 8'h80; // 초기 중간 점수
                        end
                    end
                end else begin
                    if (decay_trigger) decay_timer_cs <= '0;
                    else               decay_timer_cs <= decay_timer_cs + 1'b1;

                    // C++의 에이징(Aging) 및 감쇠(Decay) 메커니즘 반영
                    if (decay_trigger) begin
                        for (int s = 0; s < SET_COUNT; s++) begin
                            for (int w = 0; w < WAY_COUNT; w++) begin
                                custom_freq[s][w]  <= custom_freq[s][w] >> 1;
                                custom_score[s][w] <= custom_score[s][w] >> 1;
                            end
                        end
                    end

                    if (access_valid) begin
                        if (is_hit) begin
                            if (custom_freq[access_set][access_way] < 8'hFF)
                                custom_freq[access_set][access_way] <= custom_freq[access_set][access_way] + 1'b1;
                            if (custom_score[access_set][access_way] <= 8'hF8)
                                custom_score[access_set][access_way] <= custom_score[access_set][access_way] + 8'h08;
                        end else begin
                            // 미스 발생 시 신규 항목 초기화 (C++ CustomCache 생성자 및 access 초기값 대응)
                            custom_freq[access_set][access_way]  <= 8'h01;
                            custom_score[access_set][access_way] <= 8'h40;
                        end
                    end
                end
            end
        end

        // =====================================================================
        // 4. Fallback Policies (FIFO, Random)
        // =====================================================================
        else if (POLICY == POLICY_FIFO) begin : gen_fifo
            logic [WAY_IDX_WIDTH-1:0] fifo_ptr [SET_COUNT-1:0];
            assign victim_way = fifo_ptr[query_set];

            always_ff @(posedge clk) begin
                if (rst) begin
                    for (int s = 0; s < SET_COUNT; s++) fifo_ptr[s] <= '0;
                end else if (access_valid && !is_hit) begin
                    fifo_ptr[access_set] <= fifo_ptr[access_set] + 1'b1;
                end
            end
        end
        else begin : gen_random
            logic [15:0] lfsr;
            assign victim_way = lfsr[WAY_IDX_WIDTH-1:0];

            always_ff @(posedge clk) begin
                if (rst) lfsr <= 16'hACE1;
                else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            end
        end
    endgenerate

endmodule
