// Sequence SRAM operands and results for the VPU and activation datapaths.
// Their instructions do not overlap. DMA retains its own PSRAM transfer state.
module mem_ctrl
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH = 4,
    parameter int VPU_DEPTH = 4,
    parameter int ACTIVATION_DEPTH = 4,
    parameter int UB_ROWS = 32,
    parameter int DRAM_DATA_BYTES = 8
) (
    input logic clk, rst,
    input vpu_inst_type vpu_inst,
    input logic vpu_start, inst_read_wb,
    output logic vpu_busy, vpu_resource_busy, vpu_read_wb,
    input activate_inst_type activation_inst,
    input logic activation_start,
    output logic activation_busy, activation_resource_busy,

    output sram_region_type read_region, write_region,
    output buffer_addr_type read_addr, write_addr,
    output logic read_valid, write_valid, write_accumulate,
    input logic read_ready, write_ready,
    input fp8_type [COMPUTE_WIDTH-1:0] read_rsp_data,
    input logic read_rsp_valid,
    output logic read_rsp_ready,
    output fp8_type [COMPUTE_WIDTH-1:0] write_data,

    input logic sparsity_en,
    input fp8_type sparse_input_data,
    input logic sparse_input_valid,
    output logic sparse_input_ready,
    output fp8_type [COMPUTE_WIDTH-1:0] input_data, last_sum_data,
    output logic input_data_valid, last_sum_valid,
    input fp8_type [COMPUTE_WIDTH-1:0] vpu_result_data,
    input logic vpu_result_valid,

    output fp8_type [COMPUTE_WIDTH-1:0] activation_data,
    output activation_type activation_function,
    output logic activation_data_valid,
    input logic activation_data_ready,
    input fp8_type [COMPUTE_WIDTH-1:0] activation_rsp_data,
    input logic activation_rsp_valid,
    output logic activation_rsp_ready,

    // External-memory commands use a byte address and a length in beats minus one.
    output dram_addr_type                         dma_cmd_addr,
    output logic [7:0]                            dma_cmd_len,
    output logic                                  dma_cmd_write,
    output logic                                  dma_cmd_valid,
    input  logic                                  dma_cmd_ready,
    input  logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dma_rsp_data,
    input  logic                                  dma_rsp_valid,
    output logic                                  dma_rsp_ready,
    output logic [DRAM_DATA_BYTES*BYTE_WIDTH-1:0] dma_write_data,
    output logic [DRAM_DATA_BYTES-1:0]            dma_write_strb,
    output logic                                  dma_write_data_valid,
    input  logic                                  dma_write_data_ready,

    output logic [31:0]                           uart_result_data,
    output logic [2:0]                            uart_result_bytes,
    output logic                                  uart_result_valid,
    input  logic                                  uart_result_ready,

    output logic dma_busy,
    output sram_region_type dma_sram_region,

    // DMA command dispatched by the core decoder.
    input dram_inst_type dma_inst,
    input logic          dma_inst_enable,

    // DMA has its own client on the shared SRAM controller.
    output buffer_addr_type dma_sram_req_addr,
    output fp8_type [COMPUTE_WIDTH-1:0] dma_sram_req_data,
    output logic dma_sram_req_write, dma_sram_req_valid,
    input logic dma_sram_req_ready,
    input fp8_type [COMPUTE_WIDTH-1:0] dma_sram_rsp_data,
    input logic dma_sram_rsp_valid,
    output logic dma_sram_rsp_ready,

    output logic uart_range_error
);
    localparam int DEPTH = VPU_DEPTH > ACTIVATION_DEPTH ? VPU_DEPTH : ACTIVATION_DEPTH;
    localparam int PTR_BITS = $clog2(DEPTH);
    localparam int COUNT_BITS = $clog2(DEPTH+1);
    localparam int UB_AW = $clog2(UB_ROWS);
    localparam int DEST_BITS = UB_AW > ACCUMULATOR_ADDR_WIDTH ? UB_AW : ACCUMULATOR_ADDR_WIDTH;
    typedef logic [PTR_BITS-1:0] ptr_t;
    typedef logic [COUNT_BITS-1:0] count_t;
    typedef struct packed {
        logic [DEST_BITS-1:0] dest;
        logic [3:0] op;
        logic scalar_or_invalid;
        logic sparse;
        logic skip;
    } metadata_t;

    metadata_t meta_fifo [DEPTH];
    ptr_t issue_ptr, response_ptr, retire_ptr;
    count_t allocated, read_pending;
    logic activation_mode, issuing;
    logic [LENGTH_WIDTH-1:0] requests_left;
    buffer_addr_type src_addr, dst_addr;
    logic [3:0] op;
    logic scalar, sparse;
    logic fifo_full, sparse_issue, request_fire, response_fire, result_fire;
    logic result_pending, retire_skip, retire_normal, is_skip;
    logic compute_inflight, held_result_valid;
    fp8_type [COMPUTE_WIDTH-1:0] held_result;

    function automatic ptr_t next_ptr(input ptr_t ptr);
        return ptr == ptr_t'(DEPTH-1) ? '0 : ptr + 1'b1;
    endfunction

    assign vpu_busy = !activation_mode && issuing;
    assign vpu_resource_busy = !activation_mode && (issuing || allocated != 0);
    assign activation_busy = activation_mode && issuing;
    assign activation_resource_busy = activation_mode && (issuing || allocated != 0);

    // Keep each pipeline's original capacity, including activation's unused slot.
    assign fifo_full = activation_mode ? allocated == count_t'(ACTIVATION_DEPTH-1)
                                      : allocated == count_t'(VPU_DEPTH);
    assign read_region = activation_mode ? SRAM_REGION_ACC :
                         vpu_read_wb ? SRAM_REGION_WB : SRAM_REGION_UB;
    assign read_addr = src_addr;
    assign read_valid = issuing && !fifo_full && (activation_mode || !sparse);
    assign sparse_issue = !activation_mode && issuing && sparse && !fifo_full;
    assign request_fire = (read_valid && read_ready) || sparse_issue;

    assign sparse_input_ready = !activation_mode && !compute_inflight && sparse_input_valid &&
                                read_pending != 0 && meta_fifo[response_ptr].sparse;
    assign is_skip = sparsity_en && sparse_input_data[6:0] == '0;
    assign read_rsp_ready = read_pending != 0 &&
        (activation_mode ? activation_data_ready : (!compute_inflight && !meta_fifo[response_ptr].sparse));
    assign response_fire = (read_rsp_valid && read_rsp_ready) || sparse_input_ready;

    assign input_data_valid = !activation_mode && response_fire &&
                              !(meta_fifo[response_ptr].sparse && is_skip);
    assign last_sum_valid = input_data_valid;
    assign activation_data = read_rsp_data;
    assign activation_data_valid = activation_mode && read_rsp_valid && read_pending != 0;
    assign activation_function = activation_data_valid ? activation_type'(meta_fifo[response_ptr].op)
                                                       : no_activation;

    always_comb begin
        if (!input_data_valid) begin
            input_data = '0;
            last_sum_data = '0;
        end
        else begin
            case (vpu_op_type'(meta_fifo[response_ptr].op[3:1]))
                vpu_op_mul: begin
                    if (meta_fifo[response_ptr].scalar_or_invalid) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            input_data[i] = sparse_input_data;
                        end
                    end
                    else begin
                        input_data = read_rsp_data;
                    end
                    last_sum_data = '0;
                end
                vpu_op_add: begin
                    for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                        input_data[i] = FP8_ONE;
                    end
                    if (meta_fifo[response_ptr].scalar_or_invalid) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            last_sum_data[i] = read_rsp_data[0];
                        end
                    end
                    else begin
                        last_sum_data = read_rsp_data;
                    end
                end
                vpu_op_sub: begin
                    for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                        input_data[i] = FP8_NEG_ONE;
                    end
                    if (meta_fifo[response_ptr].scalar_or_invalid) begin
                        for (int i = 0; i < COMPUTE_WIDTH; ++i) begin
                            last_sum_data[i] = read_rsp_data[0];
                        end
                    end
                    else begin
                        last_sum_data = read_rsp_data;
                    end
                end
                default: begin
                    input_data = '0;
                    last_sum_data = '0;
                end
            endcase
        end
    end


    assign result_pending = allocated != read_pending;
    assign retire_skip = !activation_mode && result_pending && meta_fifo[retire_ptr].skip;
    assign retire_normal = !activation_mode && result_pending &&
                           !meta_fifo[retire_ptr].skip && held_result_valid;

    assign write_region = activation_mode ? SRAM_REGION_UB : SRAM_REGION_ACC;
    assign write_addr = result_pending ?
        ((activation_mode && meta_fifo[retire_ptr].scalar_or_invalid) ?
         '1 : buffer_addr_type'(meta_fifo[retire_ptr].dest)) : '0;
    assign write_accumulate = !activation_mode && result_pending && meta_fifo[retire_ptr].op[0];
    assign write_data = activation_mode ? activation_rsp_data : (retire_normal ? held_result : '0);
    assign write_valid = activation_mode ? (result_pending && activation_rsp_valid) :
                         (retire_normal || (retire_skip && !write_accumulate));
    assign activation_rsp_ready = activation_mode && result_pending && write_ready;
    assign result_fire = (write_valid && write_ready) || (retire_skip && write_accumulate);

    always_ff @(posedge clk) begin
        if (rst) begin
            activation_mode <= 0;
            issuing <= 0;
            vpu_read_wb <= 0;
            requests_left <= '0;
            src_addr <= '0;
            dst_addr <= '0;
            op <= '0;
            scalar <= 0;
            sparse <= 0;
            issue_ptr <= '0;
            response_ptr <= '0;
            retire_ptr <= '0;
            allocated <= '0;
            read_pending <= '0;
            compute_inflight <= 0;
            held_result_valid <= 0;
            held_result <= '0;
        end else begin
            if (vpu_start || activation_start) begin
                activation_mode <= activation_start;
                if (activation_start) begin
                    requests_left <= activation_inst.length;
                    issuing <= activation_inst.length != 0;
                    src_addr <= buffer_addr_type'(activation_inst.acc_addr);
                    dst_addr <= activation_inst.buffer_addr;
                    op <= activation_inst.opcode[3:0];
                end else begin
                    vpu_read_wb <= inst_read_wb;
                    requests_left <= vpu_inst.length;
                    issuing <= vpu_inst.length != 0;
                    src_addr <= vpu_inst.buffer_addr;
                    dst_addr <= buffer_addr_type'(vpu_inst.acc_addr);
                    op <= vpu_inst.opcode[3:0];
                    scalar <= vpu_inst.opcode[4];
                    sparse <= (vpu_inst.opcode & 8'hfe) == OPCODE_VPU_SCALAR_MUL;
                end
            end

            if (request_fire) begin
                meta_fifo[issue_ptr] <= '{
                    dest: activation_mode ? DEST_BITS'(UB_AW'(dst_addr)) : DEST_BITS'(dst_addr),
                    op: op,
                    scalar_or_invalid: activation_mode ? (int'(dst_addr) >= UB_ROWS) : scalar,
                    sparse: !activation_mode && sparse,
                    skip: 1'b0
                };
                issue_ptr <= next_ptr(issue_ptr);
                src_addr <= (src_addr + 1'b1) &
                    (activation_mode ? buffer_addr_type'({ACCUMULATOR_ADDR_WIDTH{1'b1}}) : '1);
                dst_addr <= (dst_addr + 1'b1) &
                    (activation_mode ? '1 : buffer_addr_type'({ACCUMULATOR_ADDR_WIDTH{1'b1}}));
                requests_left <= requests_left - 1'b1;
                if (requests_left == 1) issuing <= 0;
            end
            if (response_fire) begin
                if (!activation_mode) begin
                    meta_fifo[response_ptr].skip <= meta_fifo[response_ptr].sparse && is_skip;
                    compute_inflight <= 1;
                end
                response_ptr <= next_ptr(response_ptr);
            end
            if (vpu_result_valid) begin
                held_result <= vpu_result_data;
                held_result_valid <= 1;
            end
            if (result_fire) begin
                retire_ptr <= next_ptr(retire_ptr);
                if (!activation_mode) begin
                    compute_inflight <= 0;
                    held_result_valid <= 0;
                end
            end
            allocated <= allocated + request_fire - result_fire;
            read_pending <= read_pending + request_fire - response_fire;
        end
    end

`ifndef SYNTHESIS
    initial if (VPU_DEPTH < 2 || ACTIVATION_DEPTH < 2)
        $fatal(1,"mem_ctrl requires metadata depths of at least two");
    always @(posedge clk) if (!rst && (vpu_start || activation_start))
        if (issuing || (allocated != 0 && activation_mode != activation_start) ||
            (vpu_start && activation_start))
            $fatal(1,"incompatible overlapping instructions in mem_ctrl");
`endif

    dma #(
        .COMPUTE_WIDTH   (COMPUTE_WIDTH),
        .DRAM_DATA_BYTES (DRAM_DATA_BYTES)
    ) dma_engine (
        .clk                    (clk),
        .rst                    (rst),
        .inst                   (dma_inst),
        .inst_enable            (dma_inst_enable),
        .busy                   (dma_busy),
        .uart_range_error       (uart_range_error),

        .dram_cmd_addr          (dma_cmd_addr),
        .dram_cmd_len           (dma_cmd_len),
        .dram_cmd_write         (dma_cmd_write),
        .dram_cmd_valid         (dma_cmd_valid),
        .dram_cmd_ready         (dma_cmd_ready),
        .dram_rsp_data          (dma_rsp_data),
        .dram_rsp_valid         (dma_rsp_valid),
        .dram_rsp_ready         (dma_rsp_ready),
        .dram_write_data        (dma_write_data),
        .dram_write_strb        (dma_write_strb),
        .dram_write_data_valid  (dma_write_data_valid),
        .dram_write_data_ready  (dma_write_data_ready),

        .uart_result_data       (uart_result_data),
        .uart_result_bytes      (uart_result_bytes),
        .uart_result_valid      (uart_result_valid),
        .uart_result_ready      (uart_result_ready),

        .sram_region            (dma_sram_region),
        .sram_req_addr          (dma_sram_req_addr),
        .sram_req_data          (dma_sram_req_data),
        .sram_req_write         (dma_sram_req_write),
        .sram_req_valid         (dma_sram_req_valid),
        .sram_req_ready         (dma_sram_req_ready),
        .sram_rsp_data          (dma_sram_rsp_data),
        .sram_rsp_valid         (dma_sram_rsp_valid),
        .sram_rsp_ready         (dma_sram_rsp_ready)
    );
endmodule
