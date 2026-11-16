// 1D VPU flow controller.
module vpu_ctrl
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH   = 14,
    parameter int META_FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst,
    input  vpu_inst_type     inst,
    input  logic             inst_enable,

    // Address-only request -> unified buffer
    output buffer_addr_type buffer_req_addr,
    output logic            buffer_req_valid,
    input  logic            buffer_req_ready,

    // Data-only response <- unified buffer
    input  fp16_type [COMPUTE_WIDTH-1:0] buffer_rsp_data,
    input  logic                         buffer_rsp_valid,
    output logic                         buffer_rsp_ready,
    input  logic                         sparsity_en,

    input  fp16_type        sparse_input_data,
    input  logic            sparse_input_valid,
    output logic            sparse_input_ready,

    // Paired data -> 1D VPU
    output fp16_type [COMPUTE_WIDTH-1:0] input_data,
    output logic                         input_data_valid,

    output fp16_type [COMPUTE_WIDTH-1:0] last_sum_data,
    output logic                         last_sum_valid,

    // Result response <- 1D VPU
    input  fp16_type [COMPUTE_WIDTH-1:0] vpu_result_data,
    input  logic                         vpu_result_valid,

    // Paired result + metadata -> accumulator register file
    output fp16_type [COMPUTE_WIDTH-1:0] acc_data,
    output accumulator_addr_type         acc_addr,
    output logic                         accumulate,
    output logic                         acc_enable,
    input  logic                         acc_ready,

    output logic busy,
    output logic resource_busy
);

    localparam int FIFO_PTR_WIDTH = (META_FIFO_DEPTH > 1) ? $clog2(META_FIFO_DEPTH) : 1;
    localparam int FIFO_COUNT_WIDTH = $clog2(META_FIFO_DEPTH + 1);

    typedef struct packed {
        accumulator_addr_type acc_addr;
        logic                 accumulate;
        vpu_op_type           vpu_op;
        logic                 is_scalar;
        logic                 is_sparse;
        logic                 is_skip;
    } matrix_meta_type;

    // Current instruction issue state.
    logic issue_valid_cs;
    logic [LENGTH_WIDTH-1:0] requests_left_cs;
    buffer_addr_type         buffer_addr_cs;
    accumulator_addr_type    acc_addr_cs;
    logic                    accumulate_cs;
    logic                    is_scalar_cs;
    logic                    is_sparse_cs;
    vpu_op_type              vpu_op_cs;

    matrix_meta_type meta_fifo [META_FIFO_DEPTH-1:0];

    logic [FIFO_PTR_WIDTH-1:0] write_ptr_cs;
    logic [FIFO_PTR_WIDTH-1:0] buffer_rsp_ptr_cs;
    logic [FIFO_PTR_WIDTH-1:0] result_rsp_ptr_cs;

    logic [FIFO_COUNT_WIDTH-1:0] allocated_count_cs;
    logic [FIFO_COUNT_WIDTH-1:0] buffer_pending_count_cs;

    logic accept_inst;
    logic fifo_full;
    logic result_pending;
    logic request_fire;
    logic buffer_response_fire;
    logic result_fire;
    logic compute_inflight, held_result_valid;
    fp16_type [COMPUTE_WIDTH-1:0] held_result;


    logic sparsity_valid;
    logic is_skip;
    logic retire_skip;
    logic retire_normal;

    typedef logic [FIFO_PTR_WIDTH-1:0]   fifo_ptr_type;
    typedef logic [FIFO_COUNT_WIDTH-1:0] fifo_count_type;

    function automatic fifo_ptr_type next_ptr(input fifo_ptr_type ptr);
        if (ptr == fifo_ptr_type'(META_FIFO_DEPTH - 1))
            next_ptr = '0;
        else
            next_ptr = ptr + 1'b1;
    endfunction

    assign fifo_full =
        (allocated_count_cs == fifo_count_type'(META_FIFO_DEPTH));

    assign result_pending =
        (allocated_count_cs != buffer_pending_count_cs);

    assign busy          = issue_valid_cs;
    assign resource_busy = issue_valid_cs || (allocated_count_cs != '0);

    assign accept_inst = inst_enable && !issue_valid_cs;

    assign buffer_req_valid =
        issue_valid_cs && !fifo_full && !is_sparse_cs;

    assign buffer_req_addr = buffer_addr_cs;
    assign sparsity_valid = issue_valid_cs && is_sparse_cs && !fifo_full;

    assign request_fire = (buffer_req_valid && buffer_req_ready) || sparsity_valid;

    assign sparse_input_ready = !compute_inflight && sparse_input_valid && (buffer_pending_count_cs != '0) && meta_fifo[buffer_rsp_ptr_cs].is_sparse;
    assign is_skip = sparsity_en ? (sparse_input_data == '0) : '0;

    assign input_data_valid =
        buffer_response_fire && !((meta_fifo[buffer_rsp_ptr_cs].is_sparse) && is_skip);

    assign last_sum_valid = input_data_valid;

    // vpu_op에 따른 input_data 라우팅 로직 (현재는 default로 1:1 전달)
    always_comb begin
        if (!input_data_valid) begin
            input_data = '0;
            last_sum_data = '0;
        end
        else begin
            case (meta_fifo[buffer_rsp_ptr_cs].vpu_op)
                vpu_op_mul: begin
                    if (meta_fifo[buffer_rsp_ptr_cs].is_scalar) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            input_data[i] = sparse_input_data;
                        end
                    end
                    else begin
                        input_data = buffer_rsp_data;
                    end
                    last_sum_data = '0;
                end
                vpu_op_add: begin
                    for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                        input_data[i] = FP16_ONE;
                    end
                    if (meta_fifo[buffer_rsp_ptr_cs].is_scalar) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            last_sum_data[i] = buffer_rsp_data[0];
                        end
                    end
                    else begin
                        last_sum_data = buffer_rsp_data;
                    end
                end
                vpu_op_sub: begin
                    for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                        input_data[i] = FP16_NEG_ONE;
                    end
                    if (meta_fifo[buffer_rsp_ptr_cs].is_scalar) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            last_sum_data[i] = buffer_rsp_data[0];
                        end
                    end
                    else begin
                        last_sum_data = buffer_rsp_data;
                    end
                end
                default: begin
                    input_data = '0;
                    last_sum_data = '0;
                end
            endcase
        end
    end

    assign buffer_rsp_ready = !compute_inflight && (buffer_pending_count_cs != '0) && !meta_fifo[buffer_rsp_ptr_cs].is_sparse;
    assign buffer_response_fire = (buffer_rsp_valid && buffer_rsp_ready) || sparse_input_ready;

    assign retire_skip = result_pending && meta_fifo[result_rsp_ptr_cs].is_skip;
    assign retire_normal = result_pending && !meta_fifo[result_rsp_ptr_cs].is_skip && held_result_valid;
    assign result_fire = (retire_skip && meta_fifo[result_rsp_ptr_cs].accumulate) ||
                         (acc_enable && acc_ready);

    assign acc_data   = retire_normal ? held_result : '0;
    assign acc_enable = retire_normal || (retire_skip && !meta_fifo[result_rsp_ptr_cs].accumulate);
    assign acc_addr   = result_pending
        ? meta_fifo[result_rsp_ptr_cs].acc_addr
        : '0;
    assign accumulate = result_pending
        ? meta_fifo[result_rsp_ptr_cs].accumulate
        : 1'b0;

`ifndef SYNTHESIS
    initial begin
        if (META_FIFO_DEPTH < 2)
            $fatal(1, "vpu_ctrl META_FIFO_DEPTH must be at least two");
        if (COMPUTE_WIDTH < 1)
            $fatal(1, "vpu_ctrl COMPUTE_WIDTH must be positive");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            compute_inflight <= 0;
            held_result_valid <= 0;
            held_result <= '0;
            issue_valid_cs          <= 1'b0;
            requests_left_cs        <= '0;
            buffer_addr_cs          <= '0;
            acc_addr_cs             <= '0;
            accumulate_cs           <= 1'b0;
            is_scalar_cs            <= 1'b0;
            is_sparse_cs            <= 1'b0;
            vpu_op_cs               <= vpu_op_none;

            write_ptr_cs            <= '0;
            buffer_rsp_ptr_cs       <= '0;
            result_rsp_ptr_cs       <= '0;
            allocated_count_cs      <= '0;
            buffer_pending_count_cs <= '0;
        end
        else begin
            if (buffer_response_fire) compute_inflight <= 1;
            if (vpu_result_valid) begin
                held_result <= vpu_result_data;
                held_result_valid <= 1;
            end
            if (result_fire) begin
                compute_inflight <= 0;
                held_result_valid <= 0;
            end
            if (accept_inst) begin
                issue_valid_cs   <= (inst.length != '0);
                requests_left_cs <= inst.length;
                buffer_addr_cs   <= inst.buffer_addr;
                acc_addr_cs      <= inst.acc_addr;

                is_scalar_cs     <= inst.opcode[4];
                vpu_op_cs        <= vpu_op_type'(inst.opcode[3:1]);
                is_sparse_cs     <= ((inst.opcode & 8'hFE) == OPCODE_VPU_SCALAR_MUL);
                accumulate_cs    <= inst.opcode[0];
            end

            if (request_fire) begin
                meta_fifo[write_ptr_cs] <= '{
                    acc_addr:   acc_addr_cs,
                    accumulate: accumulate_cs,
                    vpu_op:     vpu_op_cs,
                    is_scalar:  is_scalar_cs,
                    is_sparse:  is_sparse_cs,
                    is_skip:    1'b0
                };
                write_ptr_cs <= next_ptr(write_ptr_cs);

                if (requests_left_cs == 1) begin
                    issue_valid_cs   <= 1'b0;
                    requests_left_cs <= '0;
                end
                else begin
                    requests_left_cs <= requests_left_cs - 1'b1;
                    buffer_addr_cs   <= buffer_addr_cs + 1'b1;
                    acc_addr_cs      <= acc_addr_cs + 1'b1;
                end
            end

            if (buffer_response_fire) begin
                meta_fifo[buffer_rsp_ptr_cs].is_skip <= 
                    meta_fifo[buffer_rsp_ptr_cs].is_sparse && is_skip;
                buffer_rsp_ptr_cs <= next_ptr(buffer_rsp_ptr_cs);
            end
                
            if (result_fire)
                result_rsp_ptr_cs <= next_ptr(result_rsp_ptr_cs);

            allocated_count_cs <=
                allocated_count_cs + request_fire - result_fire;
            buffer_pending_count_cs <=
                buffer_pending_count_cs + request_fire - buffer_response_fire;
        end
    end

endmodule
