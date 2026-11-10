// -----------------------------------------------------------------------------
// Weight-load flow controller with Sparsity Gating & Dynamic Burst Length Support.
// -----------------------------------------------------------------------------
module weight_load_ctrl
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH    = 4,
    parameter int REQ_FIFO_DEPTH   = 8
)(
    input  logic clk,
    input  logic rst,

    // Instruction decoder -> controller
    input  weight_inst_type  weight_inst,
    input  logic             weight_inst_enable,

    // Controller status -> instruction decoder
    output logic busy,
    output logic resource_busy,

    // Address-only read request -> sparse_ctrl
    output logic              sparse_req_valid,
    input  logic              sparse_req_ready,

    // Data-only response <- sparse_ctrl (1: Non-zero, 0: Zero)
    input  logic              sparse_rsp_data,
    input  logic              sparse_rsp_valid,

    // Address & Length read request -> weight cache
    output logic              weight_req_valid,
    input  logic              weight_req_ready,
    output weight_addr_type   weight_req_addr,
    output logic [7:0]        weight_req_len,

    // Address-only request -> unified buffer
    output buffer_addr_type   unified_req_addr,
    output logic              unified_req_valid,
    input  logic              unified_req_ready,

    // Data-only response <- unified buffer
    input  fp16_type [COMPUTE_WIDTH-1:0] unified_rsp_data,
    input  logic                         unified_rsp_valid,
    output logic                         unified_rsp_ready,

    // Data-only response <- weight cache
    input  fp16_type [COMPUTE_WIDTH-1:0] weight_rsp_data,
    input  logic                         weight_rsp_valid,

    // Paired weight data -> VPU
    output fp16_type [COMPUTE_WIDTH-1:0] vpu_weight_data,
    output logic                         vpu_weight_valid
);

    logic IR_valid;
    weight_addr_type weight_addr_cs;
    buffer_addr_type unified_addr_cs;
    logic            is_unified_cs;
    logic            is_dense_cs;

    logic accept_inst;
    logic sparse_req_fire;
    logic weight_req_fire;
    logic unified_req_fire;
    logic skip_fire;
    logic weight_rsp_fire;
    logic unified_rsp_fire;
    logic pending;

    assign busy          = IR_valid || pending || is_dense_cs;
    assign resource_busy = busy;

    assign accept_inst = weight_inst_enable && !busy;

    // Stage 1: sparse_ctrl로 Input 0 판정 요청
    // sparse_req_fire와 같은 cycle에 sparse_rsp_data가 유효함
    assign sparse_req_valid = IR_valid && !is_unified_cs;
    assign sparse_req_fire  = sparse_req_valid && sparse_req_ready;

    // Stage 2: Non-zero이면 Cache에 요청
    assign weight_req_valid = is_dense_cs && !pending;
    assign weight_req_addr  = weight_addr_cs;
    assign weight_req_len   = COMPUTE_WIDTH;
    assign weight_req_fire  = weight_req_valid && weight_req_ready;

    // Zero이면 Cache 요청 없이 Skip
    assign skip_fire =
        sparse_req_fire && sparse_rsp_valid && (sparse_rsp_data == 1'b0);

    // Unified Buffer 요청
    assign unified_req_valid = IR_valid && is_unified_cs;
    assign unified_req_addr  = unified_addr_cs;
    assign unified_req_fire  = unified_req_valid && unified_req_ready;

    // Stage 3: Response 수신
    assign weight_rsp_fire =
        pending && !is_unified_cs && weight_rsp_valid;

    assign unified_rsp_ready =
        pending && is_unified_cs;

    assign unified_rsp_fire =
        unified_rsp_valid && unified_rsp_ready;

    // VPU 데이터 전달
    always_comb begin
        if (is_unified_cs) begin
            vpu_weight_data  = unified_rsp_fire ? unified_rsp_data : '0;
            vpu_weight_valid = unified_rsp_fire;
        end
        else begin
            vpu_weight_data  = skip_fire ? '0 : (weight_rsp_fire ? weight_rsp_data : '0);
            vpu_weight_valid = skip_fire || weight_rsp_fire;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            IR_valid       <= 1'b0;
            weight_addr_cs <= '0;
            unified_addr_cs <= '0;
            is_unified_cs  <= 1'b0;
            is_dense_cs    <= 1'b0;
            pending        <= 1'b0;
        end
        else begin
            if (accept_inst) begin
                IR_valid        <= 1'b1;
                weight_addr_cs  <= weight_inst.weight_addr;
                unified_addr_cs <= weight_inst.unified_addr;
                is_unified_cs   <= weight_inst.is_unified;
                is_dense_cs     <= 1'b0;
            end

            // Sparse 결과는 request handshake와 같은 cycle에 소비
            if (sparse_req_fire) begin
                IR_valid <= 1'b0;

                if (sparse_rsp_data == 1'b1)
                    is_dense_cs <= 1'b1;
            end

            // Unified request 발사 후 response 대기
            if (unified_req_fire) begin
                IR_valid <= 1'b0;
                pending  <= 1'b1;
            end

            // Cache request 발사 후 response 대기
            if (weight_req_fire) begin
                is_dense_cs <= 1'b0;
                pending     <= 1'b1;
            end

            // 최종 처리 완료
            if (skip_fire || weight_rsp_fire || unified_rsp_fire) begin
                pending     <= 1'b0;
                is_dense_cs <= 1'b0;
            end
        end
    end

endmodule
