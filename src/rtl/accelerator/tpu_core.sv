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
    parameter int DRAM_DATA_BYTES              = 8,
    parameter int SRAM_BYTES                   = DEFAULT_SRAM_BYTES,
    parameter int MAX_COLUMN_ROWS              = COMPUTE_WIDTH,
    parameter int WEIGHT_BUFFER_DEPTH          = SRAM_BYTES / (4*COMPUTE_WIDTH),
    parameter int UNIFIED_BUFFER_DEPTH         = SRAM_BYTES / (2*COMPUTE_WIDTH),
    parameter int REGISTER_DEPTH               = SRAM_BYTES / (4*COMPUTE_WIDTH),
    parameter int WEIGHT_REQ_FIFO_DEPTH        = 8,
    parameter int SPARSITY_FIFO_DEPTH          = 2,
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

    fp8_type        sparse_vpu_input_data;
    logic            sparse_vpu_input_valid;
    logic            sparse_vpu_input_ready;

    logic            sparse_req_valid;
    logic            sparse_req_ready;
    buffer_addr_type sparse_req_addr;
    logic            sparse_rsp_data;
    logic            sparse_rsp_valid;

    logic                         weight_req_valid;
    logic                         weight_req_ready;
    weight_addr_type              weight_req_addr;
    fp8_type [COMPUTE_WIDTH-1:0]  weight_rsp_data;
    logic                         weight_rsp_valid;

    fp8_type [COMPUTE_WIDTH-1:0]  vpu_weight_data;
    logic                         vpu_weight_valid;

    // ---------------------------------------------------------------------
    // Unified-buffer clients
    // ---------------------------------------------------------------------

    sram_region_type compute_read_region, compute_write_region;
    buffer_addr_type compute_read_addr, compute_write_addr;
    logic compute_read_valid, compute_read_ready, compute_read_rsp_valid, compute_read_rsp_ready;
    logic compute_write_valid, compute_write_ready, compute_write_accumulate;
    fp8_type [COMPUTE_WIDTH-1:0] compute_read_rsp_data, compute_write_data;

    buffer_addr_type              sparse_buffer_req_addr;
    logic                         sparse_buffer_req_valid;
    logic                         sparse_buffer_req_ready;
    fp8_type                      sparse_buffer_rsp_data;
    logic                         sparse_buffer_rsp_valid;
    logic                         sparse_buffer_rsp_ready;

    buffer_addr_type              weight_buffer_req_addr;
    logic                         weight_buffer_req_valid;
    logic                         weight_buffer_req_ready;
    fp8_type [COMPUTE_WIDTH-1:0]  weight_buffer_rsp_data;
    logic                         weight_buffer_rsp_valid;
    logic                         weight_buffer_rsp_ready;

    // ---------------------------------------------------------------------
    // VPU datapath
    // ---------------------------------------------------------------------

    fp8_type [COMPUTE_WIDTH-1:0]  input_data;
    logic                         input_valid;
    fp8_type [COMPUTE_WIDTH-1:0]  last_sum_data;
    logic                         last_sum_valid;

    fp8_type [COMPUTE_WIDTH-1:0]  vpu_result_data;
    logic                         vpu_result_valid;

    fp8_type [COMPUTE_WIDTH-1:0]  activation_input_data;
    logic                         activation_input_valid;
    logic                         activation_input_ready;
    activation_type               activation_input_function;

    fp8_type [COMPUTE_WIDTH-1:0]  activation_output_data;
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

    logic dispatch_weight_en, dispatch_vpu_read_wb;
    logic dispatch_input_en;
    logic dispatch_vpu_en;
    logic dispatch_activation_en;
    logic dispatch_dma_en;
    logic dma_busy;
    sram_region_type dma_sram_region;
    dram_inst_type dma_inst;
    logic dma_inst_enable;
    buffer_addr_type dma_sram_req_addr;
    fp8_type [COMPUTE_WIDTH-1:0] dma_sram_req_data, dma_sram_rsp_data;
    logic dma_sram_req_write, dma_sram_req_valid, dma_sram_req_ready;
    logic dma_sram_rsp_valid, dma_sram_rsp_ready;
    logic uart_range_error;

    logic weight_busy;
    logic weight_resource_busy;
    logic input_busy;
    logic input_resource_busy;
    logic vpu_busy;
    logic vpu_resource_busy, vpu_read_wb;
    logic mem_busy, sram_error, vpu_address_error;
    logic activation_busy;
    logic activation_resource_busy;

    assign dispatch_weight_inst   = weight_inst_type'(dispatch_inst);
    assign dispatch_input_inst    = input_inst_type'(dispatch_inst);
    assign dispatch_dram_inst     = dram_inst_type'(dispatch_inst);
    assign dispatch_activate_inst = activate_inst_type'(dispatch_inst);

    assign dma_inst        = dispatch_dram_inst;
    assign dma_inst_enable = dispatch_dma_en;
    assign sparsity_en     = SPARSITY_EN;

    // ---------------------------------------------------------------------
    // Decoder
    // ---------------------------------------------------------------------

    inst_decoder #(
        .UB_ROWS(UNIFIED_BUFFER_DEPTH), .WB_ROWS(WEIGHT_BUFFER_DEPTH)
    ) decoder (
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
        .vpu_read_wb                 (vpu_read_wb),
        .vpu_resource_busy           (vpu_resource_busy),
        .activation_busy             (activation_busy),
        .activation_resource_busy    (activation_resource_busy),
        .dma_busy                    (dma_busy || mem_busy),
        .dma_engine_busy             (dma_busy),
        .dma_weight_resource_busy    (mem_busy || (dma_busy && dma_sram_region == SRAM_REGION_WB)),
        .dma_buffer_resource_busy    (mem_busy || (dma_busy && dma_sram_region == SRAM_REGION_UB)),
        .dma_acc_resource_busy       (mem_busy || (dma_busy && dma_sram_region == SRAM_REGION_ACC)),
        .dispatch_inst               (dispatch_inst),
        .dispatch_weight_en          (dispatch_weight_en),
        .dispatch_input_en          (dispatch_input_en),
        .dispatch_vpu_en             (dispatch_vpu_en),
        .dispatch_vpu_inst           (dispatch_vpu_inst),
        .dispatch_vpu_read_wb        (dispatch_vpu_read_wb),
        .vpu_address_error           (vpu_address_error),
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

    mem_ctrl #(
        .COMPUTE_WIDTH    (COMPUTE_WIDTH),
        .VPU_DEPTH        (VPU_META_FIFO_DEPTH),
        .ACTIVATION_DEPTH (ACTIVATION_META_FIFO_DEPTH),
        .UB_ROWS          (UNIFIED_BUFFER_DEPTH),
        .DRAM_DATA_BYTES  (DRAM_DATA_BYTES)
    ) memory_flow_controller (
        .clk(clk), .rst(rst),
        .vpu_inst(dispatch_vpu_inst), .vpu_start(dispatch_vpu_en),
        .inst_read_wb(dispatch_vpu_read_wb), .vpu_read_wb(vpu_read_wb),
        .vpu_busy(vpu_busy), .vpu_resource_busy(vpu_resource_busy),
        .activation_inst(dispatch_activate_inst), .activation_start(dispatch_activation_en),
        .activation_busy(activation_busy), .activation_resource_busy(activation_resource_busy),
        .read_region(compute_read_region), .read_addr(compute_read_addr),
        .read_valid(compute_read_valid), .read_ready(compute_read_ready),
        .read_rsp_data(compute_read_rsp_data), .read_rsp_valid(compute_read_rsp_valid),
        .read_rsp_ready(compute_read_rsp_ready),
        .write_region(compute_write_region), .write_addr(compute_write_addr),
        .write_valid(compute_write_valid), .write_data(compute_write_data),
        .write_accumulate(compute_write_accumulate), .write_ready(compute_write_ready),
        .sparsity_en(sparsity_en), .sparse_input_data(sparse_vpu_input_data),
        .sparse_input_valid(sparse_vpu_input_valid), .sparse_input_ready(sparse_vpu_input_ready),
        .input_data(input_data), .input_data_valid(input_valid),
        .last_sum_data(last_sum_data), .last_sum_valid(last_sum_valid),
        .vpu_result_data(vpu_result_data), .vpu_result_valid(vpu_result_valid),
        .activation_data(activation_input_data), .activation_data_valid(activation_input_valid),
        .activation_data_ready(activation_input_ready), .activation_function(activation_input_function),
        .activation_rsp_data(activation_output_data), .activation_rsp_valid(activation_output_valid),
        .activation_rsp_ready(activation_output_ready),
        .dma_cmd_addr              (dma_cmd_addr),
        .dma_cmd_len               (dma_cmd_len),
        .dma_cmd_write             (dma_cmd_write),
        .dma_cmd_valid             (dma_cmd_valid),
        .dma_cmd_ready             (dma_cmd_ready),
        .dma_rsp_data              (dma_rsp_data),
        .dma_rsp_valid             (dma_rsp_valid),
        .dma_rsp_ready             (dma_rsp_ready),
        .dma_write_data            (dma_write_data),
        .dma_write_strb            (dma_write_strb),
        .dma_write_data_valid      (dma_write_data_valid),
        .dma_write_data_ready      (dma_write_data_ready),
        .uart_result_data          (uart_result_data),
        .uart_result_bytes         (uart_result_bytes),
        .uart_result_valid         (uart_result_valid),
        .uart_result_ready         (uart_result_ready),
        .dma_busy                  (dma_busy),
        .dma_sram_region           (dma_sram_region),
        .dma_inst                  (dma_inst),
        .dma_inst_enable           (dma_inst_enable),
        .dma_sram_req_addr         (dma_sram_req_addr),
        .dma_sram_req_data         (dma_sram_req_data),
        .dma_sram_req_write        (dma_sram_req_write),
        .dma_sram_req_valid        (dma_sram_req_valid),
        .dma_sram_req_ready        (dma_sram_req_ready),
        .dma_sram_rsp_data         (dma_sram_rsp_data),
        .dma_sram_rsp_valid        (dma_sram_rsp_valid),
        .dma_sram_rsp_ready        (dma_sram_rsp_ready),
        .uart_range_error          (uart_range_error)
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

    // One request channel per compute client, plus one for DMA.
    localparam int SRAM_CLIENTS = 6;
    localparam int DMA_CLIENT = SRAM_CLIENTS-1;
    logic [SRAM_CLIENTS-1:0] m_valid, m_ready, m_write, m_accumulate, m_rsp_valid, m_rsp_ready;
    logic [SRAM_CLIENTS-1:0][1:0] m_region;
    logic [SRAM_CLIENTS-1:0][23:0] m_addr;
    logic [SRAM_CLIENTS-1:0][8*COMPUTE_WIDTH-1:0] m_wdata, m_rdata;
    assign m_valid[0] = weight_req_valid;
    assign weight_req_ready = m_ready[0];
    assign m_region[0] = SRAM_REGION_WB;
    assign m_addr[0] = 24'(weight_req_addr);
    assign m_write[0] = 1'b0;
    assign m_wdata[0] = '0;
    assign m_accumulate[0] = '0;
    assign m_rsp_ready[0] = 1'b1;
    assign weight_rsp_valid = m_rsp_valid[0];
    assign weight_rsp_data = m_rdata[0];
    assign m_valid[1] = compute_read_valid;
    assign compute_read_ready = m_ready[1];
    assign m_region[1] = compute_read_region;
    assign m_addr[1] = 24'(compute_read_addr);
    assign m_write[1] = 1'b0;
    assign m_wdata[1] = '0;
    assign m_accumulate[1] = '0;
    assign m_rsp_ready[1] = compute_read_rsp_ready;
    assign compute_read_rsp_valid = m_rsp_valid[1];
    assign compute_read_rsp_data = m_rdata[1];
    assign m_valid[2] = weight_buffer_req_valid;
    assign weight_buffer_req_ready = m_ready[2];
    assign m_region[2] = SRAM_REGION_UB;
    assign m_addr[2] = 24'(weight_buffer_req_addr);
    assign m_write[2] = 1'b0;
    assign m_wdata[2] = '0;
    assign m_accumulate[2] = '0;
    assign m_rsp_ready[2] = weight_buffer_rsp_ready;
    assign weight_buffer_rsp_valid = m_rsp_valid[2];
    assign weight_buffer_rsp_data = m_rdata[2];
    assign m_valid[3] = sparse_buffer_req_valid;
    assign sparse_buffer_req_ready = m_ready[3];
    assign m_region[3] = SRAM_REGION_UB;
    assign m_addr[3] = 24'(sparse_buffer_req_addr);
    assign m_write[3] = 1'b0;
    assign m_wdata[3] = '0;
    assign m_accumulate[3] = '0;
    assign m_rsp_ready[3] = sparse_buffer_rsp_ready;
    assign sparse_buffer_rsp_valid = m_rsp_valid[3];
    assign sparse_buffer_rsp_data = m_rdata[3][7:0];
    assign m_valid[4] = compute_write_valid;
    assign compute_write_ready = m_ready[4];
    assign m_region[4] = compute_write_region;
    assign m_addr[4] = 24'(compute_write_addr);
    assign m_write[4] = 1'b1;
    assign m_wdata[4] = compute_write_data;
    assign m_accumulate[4] = compute_write_accumulate;
    assign m_rsp_ready[4] = '1;
    assign m_valid[DMA_CLIENT] = dma_sram_req_valid;
    assign dma_sram_req_ready = m_ready[DMA_CLIENT];
    assign m_region[DMA_CLIENT] = dma_sram_region;
    assign m_addr[DMA_CLIENT] = 24'(dma_sram_req_addr);
    assign m_write[DMA_CLIENT] = dma_sram_req_write;
    assign m_wdata[DMA_CLIENT] = dma_sram_req_data;
    assign m_accumulate[DMA_CLIENT] = 1'b0;
    assign m_rsp_ready[DMA_CLIENT] = dma_sram_rsp_ready;
    assign dma_sram_rsp_valid = m_rsp_valid[DMA_CLIENT];
    assign dma_sram_rsp_data = m_rdata[DMA_CLIENT];

    assign memory_error = sram_error || vpu_address_error || uart_range_error;

    sram_controller #(.SRAM_BYTES(SRAM_BYTES), .CLIENTS(SRAM_CLIENTS),
               .COMPUTE_WIDTH(COMPUTE_WIDTH), .UB_ROWS(UNIFIED_BUFFER_DEPTH),
               .ACC_ROWS(REGISTER_DEPTH), .WB_ROWS(WEIGHT_BUFFER_DEPTH)) memory_controller (
        .clk(clk), .rst(rst), .req_valid(m_valid), .req_ready(m_ready),
        .req_write(m_write), .req_accumulate(m_accumulate), .req_region(m_region),
        .req_addr(m_addr), .req_data(m_wdata), .rsp_valid(m_rsp_valid),
        .rsp_ready(m_rsp_ready), .rsp_data(m_rdata), .busy(mem_busy), .error(sram_error)
    );
`ifndef SYNTHESIS
    initial if (COMPUTE_WIDTH != 2 && COMPUTE_WIDTH != 4) $fatal(1,"Shared memory requires two or four FP8 lanes");
`endif
endmodule
