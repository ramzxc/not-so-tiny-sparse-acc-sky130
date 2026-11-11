// TPU execution core.
//
// Responsibilities:
//   * Decode and dispatch 64-bit instructions with resource dependencies
//   * Connect the weight, VPU, activation, and element-wise VPU pipelines
//   * Connect DMA traffic to the weight, unified, and accumulation memories
module tpu_core
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH                = 2,
    parameter int SRAM_BYTES                   = DEFAULT_SRAM_BYTES,
    parameter int MAX_COLUMN_ROWS              = COMPUTE_WIDTH,
    parameter int WEIGHT_BUFFER_DEPTH          = SRAM_BYTES / 16,
    parameter int UNIFIED_BUFFER_DEPTH         = SRAM_BYTES / 8,
    parameter int REGISTER_DEPTH               = SRAM_BYTES / 16,
    parameter int WEIGHT_REQ_FIFO_DEPTH        = 8,
    parameter int SPARSITY_FIFO_DEPTH          = 4,
    parameter int VPU_META_FIFO_DEPTH          = 4,
    parameter int ACTIVATION_META_FIFO_DEPTH   = 4,
    parameter int WEIGHT_CTR_WIDTH =
        (COMPUTE_WIDTH > 1) ? $clog2(COMPUTE_WIDTH) : 1,
    
    parameter bit SPARSITY_EN                  = 1'b1
)(
    input logic clk,
    input logic rst,

    input inst_type inst_port,
    input logic     inst_enable,

    // DMA status consumed by the instruction decoder.
    input logic dma_busy,
    input logic dma_weight_resource_busy,
    input logic dma_buffer_resource_busy,
    input logic dma_acc_resource_busy,

    // DMA command dispatched by the core decoder.
    output dram_inst_type dma_inst,
    output logic          dma_inst_enable,

    // DMA -> explicitly preloaded weight buffer.
    input weight_addr_type dma_weight_write_addr,
    input fp16_type [COMPUTE_WIDTH-1:0] dma_weight_write_data,
    input logic dma_weight_write_valid,
    output logic dma_weight_write_ready,

    // DMA -> unified-buffer load-write path.
    input  buffer_addr_type              dma_buffer_write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] dma_buffer_write_data,
    input  logic                         dma_buffer_write_valid,
    output logic                         dma_buffer_write_ready,

    // DMA -> unified-buffer store-read request/response path.
    input  buffer_addr_type              dma_buffer_read_req_addr,
    input  logic                         dma_buffer_read_req_valid,
    output logic                         dma_buffer_read_req_ready,
    output fp16_type [COMPUTE_WIDTH-1:0] dma_buffer_read_rsp_data,
    output logic                         dma_buffer_read_rsp_valid,
    input  logic                         dma_buffer_read_rsp_ready,

    // DMA -> accumulation-buffer store-read request/response.
    input  accumulator_addr_type         dma_acc_read_req_addr,
    input  logic                         dma_acc_read_req_valid,
    output logic                         dma_acc_read_req_ready,
    output fp16_type [COMPUTE_WIDTH-1:0] dma_acc_read_rsp_data,
    output logic                         dma_acc_read_rsp_valid,
    input  logic                         dma_acc_read_rsp_ready,

    // DMA -> accumulation-buffer restore-write path.
    input  accumulator_addr_type         dma_acc_write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] dma_acc_write_data,
    input  logic                         dma_acc_write_valid,
    output logic                         dma_acc_write_ready,

    output logic memory_error,
    output logic busy,
    output logic synchronize
);

    // ---------------------------------------------------------------------
    // Sparse-Ctrl 
    // ---------------------------------------------------------------------
    logic            sparsity_en;

    // ---------------------------------------------------------------------
    // Weight-buffer / Flow-ctrl -> VPU path
    // ---------------------------------------------------------------------

    fp16_type        sparse_vpu_input_data;
    logic            sparse_vpu_input_valid;
    logic            sparse_vpu_input_ready;

    logic            sparse_req_valid;
    logic            sparse_req_ready;
    buffer_addr_type sparse_req_addr;
    logic            sparse_rsp_data;
    logic            sparse_rsp_valid;

    logic            weight_req_valid;
    logic            weight_req_ready;
    weight_addr_type weight_req_addr;
    fp16_type [COMPUTE_WIDTH-1:0] weight_rsp_data;
    logic                         weight_rsp_valid;

    fp16_type [COMPUTE_WIDTH-1:0] vpu_weight_data;
    logic                         vpu_weight_valid;

    // ---------------------------------------------------------------------
    // Unified-buffer clients
    // ---------------------------------------------------------------------

    buffer_addr_type              vpu_buffer_req_addr;
    logic                         vpu_buffer_req_valid;
    logic                         vpu_buffer_req_ready;
    fp16_type [COMPUTE_WIDTH-1:0] vpu_buffer_rsp_data;
    logic                         vpu_buffer_rsp_valid;
    logic                         vpu_buffer_rsp_ready;

    buffer_addr_type              sparse_buffer_req_addr;
    logic                         sparse_buffer_req_valid;
    logic                         sparse_buffer_req_ready;
    fp16_type                     sparse_buffer_rsp_data;
    logic                         sparse_buffer_rsp_valid;
    logic                         sparse_buffer_rsp_ready;

    buffer_addr_type              weight_buffer_req_addr;
    logic                         weight_buffer_req_valid;
    logic                         weight_buffer_req_ready;
    fp16_type [COMPUTE_WIDTH-1:0] weight_buffer_rsp_data;
    logic                         weight_buffer_rsp_valid;
    logic                         weight_buffer_rsp_ready;

    buffer_addr_type              activation_buffer_write_addr;
    fp16_type [COMPUTE_WIDTH-1:0] activation_buffer_write_data;
    logic                         activation_buffer_write_valid;
    logic                         activation_buffer_write_ready;

    // ---------------------------------------------------------------------
    // VPU datapath
    // ---------------------------------------------------------------------

    fp16_type [COMPUTE_WIDTH-1:0] input_data;
    logic                         input_valid;
    fp16_type [COMPUTE_WIDTH-1:0] last_sum_data;
    logic                         last_sum_valid;

    fp16_type [COMPUTE_WIDTH-1:0] vpu_result_data;
    logic                         vpu_result_valid;

    fp16_type [COMPUTE_WIDTH-1:0] vpu_acc_write_data;
    accumulator_addr_type         vpu_acc_write_addr;
    logic                         vpu_acc_write_valid;
    logic                         vpu_acc_accumulate;

    // ---------------------------------------------------------------------
    // Physical accumulation-buffer write port arbitration
    // ---------------------------------------------------------------------

    accumulator_addr_type         activation_acc_req_addr;
    logic                         activation_acc_req_valid;
    logic                         activation_acc_req_ready;
    fp16_type [COMPUTE_WIDTH-1:0] activation_acc_rsp_data;
    logic                         activation_acc_rsp_valid;
    logic                         activation_acc_rsp_ready;

    fp16_type [COMPUTE_WIDTH-1:0] activation_input_data;
    logic                         activation_input_valid;
    logic                         activation_input_ready;
    activation_type               activation_input_function;

    fp16_type [COMPUTE_WIDTH-1:0] activation_output_data;
    logic                         activation_output_valid;
    logic                         activation_output_ready;

    // ---------------------------------------------------------------------
    // Instruction dispatch and resource state
    // ---------------------------------------------------------------------

    inst_type          dispatch_inst;
    weight_inst_type   dispatch_weight_inst;
    input_inst_type    dispatch_input_inst;
    vpu_inst_type      dispatch_vpu_inst;
    dram_inst_type     dispatch_dram_inst;
    activate_inst_type dispatch_activate_inst;

    logic dispatch_weight_en;
    logic dispatch_input_en;
    logic dispatch_vpu_en;
    logic dispatch_activation_en;
    logic dispatch_dma_en;

    logic weight_busy;
    logic weight_resource_busy;
    logic input_busy;
    logic input_resource_busy;
    logic vpu_busy;
    logic vpu_resource_busy;
    logic mem_busy;
    logic vpu_acc_write_ready;
    logic activation_busy;
    logic activation_resource_busy;

    assign dispatch_weight_inst   = weight_inst_type'(dispatch_inst);
    assign dispatch_input_inst    = input_inst_type'(dispatch_inst);
    assign dispatch_vpu_inst      = vpu_inst_type'(dispatch_inst);
    assign dispatch_dram_inst     = dram_inst_type'(dispatch_inst);
    assign dispatch_activate_inst = activate_inst_type'(dispatch_inst);

    assign dma_inst        = dispatch_dram_inst;
    assign dma_inst_enable = dispatch_dma_en;
    assign sparsity_en     = SPARSITY_EN;

    // ---------------------------------------------------------------------
    // Decoder
    // ---------------------------------------------------------------------

    inst_decoder decoder (
        .clk                         (clk),
        .rst                         (rst),
        .inst_in                     (inst_port),
        .inst_write                  (inst_enable),
        .decoder_busy                (busy),
        .weight_busy                 (weight_busy),
        .weight_resource_busy        (weight_resource_busy),
        .input_busy                  (input_busy),
        .input_resource_busy         (input_resource_busy),
        .vpu_busy                    (vpu_busy),
        .vpu_resource_busy           (vpu_resource_busy),
        .activation_busy             (activation_busy),
        .activation_resource_busy    (activation_resource_busy),
        .dma_busy                    (dma_busy || mem_busy),
        .dma_weight_resource_busy    (dma_weight_resource_busy || mem_busy),
        .dma_buffer_resource_busy    (dma_buffer_resource_busy || mem_busy),
        .dma_acc_resource_busy       (dma_acc_resource_busy || mem_busy),
        .dispatch_inst               (dispatch_inst),
        .dispatch_weight_en          (dispatch_weight_en),
        .dispatch_input_en          (dispatch_input_en),
        .dispatch_vpu_en             (dispatch_vpu_en),
        .dispatch_activation_en      (dispatch_activation_en),
        .dispatch_dma_en             (dispatch_dma_en),
        .synchronize                 (synchronize)
    );

    // ---------------------------------------------------------------------
    // Weight load controller, Sparsity Controller, and Weight Cache
    // ---------------------------------------------------------------------

    sparsity_ctrl #(
        .META_FIFO_DEPTH  (SPARSITY_FIFO_DEPTH),
        .UB_ROWS          (UNIFIED_BUFFER_DEPTH)
    ) sparsity_flow_controller (
        .clk                   (clk),
        .rst                   (rst),
        .input_inst            (dispatch_input_inst),
        .input_inst_enable     (dispatch_input_en),
        .busy                  (input_busy),
        .resource_busy         (input_resource_busy),
        .vpu_input_data        (sparse_vpu_input_data),
        .vpu_input_valid       (sparse_vpu_input_valid),
        .vpu_input_ready       (sparse_vpu_input_ready),
        .sparse_req_valid      (sparse_req_valid),
        .sparse_req_ready      (sparse_req_ready),
        .sparse_rsp_data       (sparse_rsp_data),
        .sparse_rsp_valid      (sparse_rsp_valid),
        .input_read_req_addr   (sparse_buffer_req_addr),
        .input_read_req_valid  (sparse_buffer_req_valid),
        .input_read_req_ready  (sparse_buffer_req_ready),
        .input_read_rsp_data   (sparse_buffer_rsp_data),
        .input_read_rsp_valid  (sparse_buffer_rsp_valid),
        .input_read_rsp_ready  (sparse_buffer_rsp_ready),
        .sparsity_en           (sparsity_en)
    );

    weight_load_ctrl #(
        .COMPUTE_WIDTH   (COMPUTE_WIDTH),
        .REQ_FIFO_DEPTH  (WEIGHT_REQ_FIFO_DEPTH)
    ) weight_flow_controller (
        .clk               (clk),
        .rst               (rst),
        .weight_inst       (dispatch_weight_inst),
        .weight_inst_enable(dispatch_weight_en),
        .busy              (weight_busy),
        .resource_busy     (weight_resource_busy),
        .sparse_req_valid  (sparse_req_valid),
        .sparse_req_ready  (sparse_req_ready),
        .sparse_rsp_data   (sparse_rsp_data),
        .sparse_rsp_valid  (sparse_rsp_valid),
        .weight_req_valid  (weight_req_valid),
        .weight_req_ready  (weight_req_ready),
        .weight_req_addr   (weight_req_addr),
        .weight_rsp_data   (weight_rsp_data),
        .weight_rsp_valid  (weight_rsp_valid),
        .unified_req_addr  (weight_buffer_req_addr),
        .unified_req_valid (weight_buffer_req_valid),
        .unified_req_ready (weight_buffer_req_ready),
        .unified_rsp_data  (weight_buffer_rsp_data),
        .unified_rsp_valid (weight_buffer_rsp_valid),
        .unified_rsp_ready (weight_buffer_rsp_ready),
        .vpu_weight_data   (vpu_weight_data),
        .vpu_weight_valid  (vpu_weight_valid)
    );

    // ---------------------------------------------------------------------
    // VPU execution path
    // ---------------------------------------------------------------------

    vpu_ctrl #(
        .COMPUTE_WIDTH   (COMPUTE_WIDTH),
        .META_FIFO_DEPTH (VPU_META_FIFO_DEPTH)
    ) vpu_flow_controller (
        .clk                 (clk),
        .rst                 (rst),
        .inst                (dispatch_vpu_inst),
        .inst_enable         (dispatch_vpu_en),
        .buffer_req_addr     (vpu_buffer_req_addr),
        .buffer_req_valid    (vpu_buffer_req_valid),
        .buffer_req_ready    (vpu_buffer_req_ready),
        .buffer_rsp_data     (vpu_buffer_rsp_data),
        .buffer_rsp_valid    (vpu_buffer_rsp_valid),
        .buffer_rsp_ready    (vpu_buffer_rsp_ready),
        .sparse_input_data   (sparse_vpu_input_data),
        .sparse_input_valid  (sparse_vpu_input_valid),
        .sparse_input_ready  (sparse_vpu_input_ready),
        .sparsity_en         (sparsity_en),
        .input_data          (input_data),
        .input_data_valid    (input_valid),
        .last_sum_data       (last_sum_data),
        .last_sum_valid      (last_sum_valid),
        .vpu_result_data     (vpu_result_data),
        .vpu_result_valid    (vpu_result_valid),
        .acc_data            (vpu_acc_write_data),
        .acc_addr            (vpu_acc_write_addr),
        .accumulate          (vpu_acc_accumulate),
        .acc_enable          (vpu_acc_write_valid),
        .acc_ready           (vpu_acc_write_ready),
        .busy                (vpu_busy),
        .resource_busy       (vpu_resource_busy)
    );

    vpu #(
        .COMPUTE_WIDTH     (COMPUTE_WIDTH)
    ) vpu_core (
        .clk             (clk),
        .rst             (rst),
        .weight_data     (vpu_weight_data),
        .load_weight     (vpu_weight_valid),
        .input_data      (input_data),
        .input_valid     (input_valid),
        .last_sum_data   (last_sum_data),
        .last_sum_valid  (last_sum_valid),
        .result          (vpu_result_data),
        .result_valid    (vpu_result_valid)
    );

    // ---------------------------------------------------------------------
    // Activation path
    // ---------------------------------------------------------------------

    activation_ctrl #(
        .COMPUTE_WIDTH   (COMPUTE_WIDTH),
        .META_FIFO_DEPTH (ACTIVATION_META_FIFO_DEPTH),
        .UB_ROWS         (UNIFIED_BUFFER_DEPTH)
    ) activation_flow_controller (
        .clk                    (clk),
        .rst                    (rst),
        .inst                   (dispatch_activate_inst),
        .inst_enable            (dispatch_activation_en),
        .acc_req_addr           (activation_acc_req_addr),
        .acc_req_valid          (activation_acc_req_valid),
        .acc_req_ready          (activation_acc_req_ready),
        .acc_rsp_data           (activation_acc_rsp_data),
        .acc_rsp_valid          (activation_acc_rsp_valid),
        .acc_rsp_ready          (activation_acc_rsp_ready),
        .activation_data        (activation_input_data),
        .activation_data_valid  (activation_input_valid),
        .activation_data_ready  (activation_input_ready),
        .activation_function    (activation_input_function),
        .activation_rsp_data    (activation_output_data),
        .activation_rsp_valid   (activation_output_valid),
        .activation_rsp_ready   (activation_output_ready),
        .buffer_write_addr      (activation_buffer_write_addr),
        .buffer_write_data      (activation_buffer_write_data),
        .buffer_write_valid     (activation_buffer_write_valid),
        .buffer_write_ready     (activation_buffer_write_ready),
        .busy                   (activation_busy),
        .resource_busy          (activation_resource_busy)
    );

    activation #(
        .COMPUTE_WIDTH (COMPUTE_WIDTH)
    ) activation_core (
        .clk                 (clk),
        .rst                 (rst),
        .data_in             (activation_input_data),
        .data_in_valid       (activation_input_valid),
        .data_in_ready       (activation_input_ready),
        .activation_function (activation_input_function),
        .data_out            (activation_output_data),
        .data_out_valid      (activation_output_valid),
        .data_out_ready      (activation_output_ready)
    );

    // One request channel per former WB/UB/ACC client.
    logic [11:0] m_valid, m_ready, m_write, m_accumulate, m_rsp_valid, m_rsp_ready;
    logic [11:0][1:0] m_region;
    logic [11:0][23:0] m_addr;
    logic [11:0][31:0] m_wdata, m_rdata;
    assign m_valid[0] = weight_req_valid;
    assign weight_req_ready = m_ready[0];
    assign m_region[0] = 2'd2;
    assign m_addr[0] = 24'(weight_req_addr);
    assign m_write[0] = 1'b0;
    assign m_wdata[0] = '0;
    assign m_accumulate[0] = '0;
    assign m_rsp_ready[0] = 1'b1;
    assign weight_rsp_valid = m_rsp_valid[0];
    assign weight_rsp_data = m_rdata[0];
    assign m_valid[1] = dma_weight_write_valid;
    assign dma_weight_write_ready = m_ready[1];
    assign m_region[1] = 2'd2;
    assign m_addr[1] = 24'(dma_weight_write_addr);
    assign m_write[1] = 1'b1;
    assign m_wdata[1] = dma_weight_write_data;
    assign m_accumulate[1] = '0;
    assign m_rsp_ready[1] = '1;
    assign m_valid[2] = vpu_buffer_req_valid;
    assign vpu_buffer_req_ready = m_ready[2];
    assign m_region[2] = 2'd0;
    assign m_addr[2] = 24'(vpu_buffer_req_addr);
    assign m_write[2] = 1'b0;
    assign m_wdata[2] = '0;
    assign m_accumulate[2] = '0;
    assign m_rsp_ready[2] = vpu_buffer_rsp_ready;
    assign vpu_buffer_rsp_valid = m_rsp_valid[2];
    assign vpu_buffer_rsp_data = m_rdata[2];
    assign m_valid[3] = weight_buffer_req_valid;
    assign weight_buffer_req_ready = m_ready[3];
    assign m_region[3] = 2'd0;
    assign m_addr[3] = 24'(weight_buffer_req_addr);
    assign m_write[3] = 1'b0;
    assign m_wdata[3] = '0;
    assign m_accumulate[3] = '0;
    assign m_rsp_ready[3] = weight_buffer_rsp_ready;
    assign weight_buffer_rsp_valid = m_rsp_valid[3];
    assign weight_buffer_rsp_data = m_rdata[3];
    assign m_valid[4] = sparse_buffer_req_valid;
    assign sparse_buffer_req_ready = m_ready[4];
    assign m_region[4] = 2'd0;
    assign m_addr[4] = 24'(sparse_buffer_req_addr);
    assign m_write[4] = 1'b0;
    assign m_wdata[4] = '0;
    assign m_accumulate[4] = '0;
    assign m_rsp_ready[4] = sparse_buffer_rsp_ready;
    assign sparse_buffer_rsp_valid = m_rsp_valid[4];
    assign sparse_buffer_rsp_data = m_rdata[4][15:0];
    assign m_valid[5] = dma_buffer_read_req_valid;
    assign dma_buffer_read_req_ready = m_ready[5];
    assign m_region[5] = 2'd0;
    assign m_addr[5] = 24'(dma_buffer_read_req_addr);
    assign m_write[5] = 1'b0;
    assign m_wdata[5] = '0;
    assign m_accumulate[5] = '0;
    assign m_rsp_ready[5] = dma_buffer_read_rsp_ready;
    assign dma_buffer_read_rsp_valid = m_rsp_valid[5];
    assign dma_buffer_read_rsp_data = m_rdata[5];
    assign m_valid[6] = activation_buffer_write_valid;
    assign activation_buffer_write_ready = m_ready[6];
    assign m_region[6] = 2'd0;
    assign m_addr[6] = 24'(activation_buffer_write_addr);
    assign m_write[6] = 1'b1;
    assign m_wdata[6] = activation_buffer_write_data;
    assign m_accumulate[6] = '0;
    assign m_rsp_ready[6] = '1;
    assign m_valid[7] = dma_buffer_write_valid;
    assign dma_buffer_write_ready = m_ready[7];
    assign m_region[7] = 2'd0;
    assign m_addr[7] = 24'(dma_buffer_write_addr);
    assign m_write[7] = 1'b1;
    assign m_wdata[7] = dma_buffer_write_data;
    assign m_accumulate[7] = '0;
    assign m_rsp_ready[7] = '1;
    assign m_valid[8] = activation_acc_req_valid;
    assign activation_acc_req_ready = m_ready[8];
    assign m_region[8] = 2'd1;
    assign m_addr[8] = 24'(activation_acc_req_addr);
    assign m_write[8] = 1'b0;
    assign m_wdata[8] = '0;
    assign m_accumulate[8] = '0;
    assign m_rsp_ready[8] = activation_acc_rsp_ready;
    assign activation_acc_rsp_valid = m_rsp_valid[8];
    assign activation_acc_rsp_data = m_rdata[8];
    assign m_valid[9] = dma_acc_read_req_valid;
    assign dma_acc_read_req_ready = m_ready[9];
    assign m_region[9] = 2'd1;
    assign m_addr[9] = 24'(dma_acc_read_req_addr);
    assign m_write[9] = 1'b0;
    assign m_wdata[9] = '0;
    assign m_accumulate[9] = '0;
    assign m_rsp_ready[9] = dma_acc_read_rsp_ready;
    assign dma_acc_read_rsp_valid = m_rsp_valid[9];
    assign dma_acc_read_rsp_data = m_rdata[9];
    assign m_valid[10] = vpu_acc_write_valid;
    assign vpu_acc_write_ready = m_ready[10];
    assign m_region[10] = 2'd1;
    assign m_addr[10] = 24'(vpu_acc_write_addr);
    assign m_write[10] = 1'b1;
    assign m_wdata[10] = vpu_acc_write_data;
    assign m_accumulate[10] = vpu_acc_accumulate;
    assign m_rsp_ready[10] = '1;
    assign m_valid[11] = dma_acc_write_valid;
    assign dma_acc_write_ready = m_ready[11];
    assign m_region[11] = 2'd1;
    assign m_addr[11] = 24'(dma_acc_write_addr);
    assign m_write[11] = 1'b1;
    assign m_wdata[11] = dma_acc_write_data;
    assign m_accumulate[11] = '0;
    assign m_rsp_ready[11] = '1;
    mem_ctrl #(.SRAM_BYTES(SRAM_BYTES), .UB_ROWS(UNIFIED_BUFFER_DEPTH),
               .ACC_ROWS(REGISTER_DEPTH), .WB_ROWS(WEIGHT_BUFFER_DEPTH)) memory_controller (
        .clk(clk), .rst(rst), .req_valid(m_valid), .req_ready(m_ready),
        .req_write(m_write), .req_accumulate(m_accumulate), .req_region(m_region),
        .req_addr(m_addr), .req_data(m_wdata), .rsp_valid(m_rsp_valid),
        .rsp_ready(m_rsp_ready), .rsp_data(m_rdata), .busy(mem_busy), .error(memory_error)
    );
`ifndef SYNTHESIS
    initial if (COMPUTE_WIDTH != 2) $fatal(1,"Shared memory currently requires two FP16 lanes");
`endif
endmodule
