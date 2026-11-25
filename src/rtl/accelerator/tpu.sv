// TPU system top level.
//
// Responsibilities:
//   * Queue 64-bit host instructions
//   * Connect the instruction core to the DMA and local memories (with explicit weight-buffer preloads)
//   * Expose the DMA memory request and data channels
module tpu
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH          = 2,
    parameter int SRAM_BYTES             = DEFAULT_SRAM_BYTES,
    parameter int WEIGHT_BUFFER_DEPTH    = SRAM_BYTES / (4*COMPUTE_WIDTH),
    parameter int UNIFIED_BUFFER_DEPTH   = SRAM_BYTES / (2*COMPUTE_WIDTH),
    parameter int DRAM_DATA_BYTES         = 8,
    parameter int REGISTER_DEPTH         = SRAM_BYTES / (4*COMPUTE_WIDTH)
)(
    input logic clk,
    input logic rst,

    // ------------------------------------------------------------------
    // HOST -> TPU core (instruction)
    // ------------------------------------------------------------------
    input        inst_type inst_word,
    input  logic inst_write_enable,
    output logic inst_fifo_empty,
    output logic inst_fifo_full,

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

    // synchronize done
    output logic synchronize
);

    // ------------------------------------------------------------------
    // Instruction FIFO -> TPU core
    // ------------------------------------------------------------------

    inst_type inst;
    logic inst_pop;
    logic core_busy;

    // ------------------------------------------------------------------
    // TPU core <-> DMA command/status interface
    // ------------------------------------------------------------------

    dram_inst_type dma_inst;
    logic          dma_inst_enable;
    logic dma_busy;
    logic core_memory_error, uart_range_error;

    assign memory_error = core_memory_error || uart_range_error;

    sram_region_type dma_sram_region;
    buffer_addr_type dma_sram_req_addr;
    fp8_type [COMPUTE_WIDTH-1:0] dma_sram_req_data, dma_sram_rsp_data;
    logic dma_sram_req_write, dma_sram_req_valid, dma_sram_req_ready;
    logic dma_sram_rsp_valid, dma_sram_rsp_ready;

    // ------------------------------------------------------------------
    // Instruction queue
    // ------------------------------------------------------------------

    inst_fifo #(
        .FIFO_DEPTH (2)
    ) instruction_fifo (
        .clk        (clk),
        .rst        (rst),
        .word       (inst_word),
        .write_en   (inst_write_enable),
        .core_busy  (core_busy),
        .data_out   (inst),
        .inst_pop   (inst_pop),
        .empty      (inst_fifo_empty),
        .full       (inst_fifo_full)
    );

    // ------------------------------------------------------------------
    // TPU core with software-managed weight SRAM
    // ------------------------------------------------------------------

    tpu_core #(
        .COMPUTE_WIDTH         (COMPUTE_WIDTH),
        .SRAM_BYTES            (SRAM_BYTES),
        .WEIGHT_BUFFER_DEPTH   (WEIGHT_BUFFER_DEPTH),
        .UNIFIED_BUFFER_DEPTH  (UNIFIED_BUFFER_DEPTH),
        .REGISTER_DEPTH        (REGISTER_DEPTH)
    ) tpu_core_tpu (
        .clk                          (clk),
        .rst                          (rst),
        .inst_port                    (inst),
        .inst_enable                  (inst_pop),
        .dma_busy                     (dma_busy),
        .dma_inst                     (dma_inst),
        .dma_inst_enable              (dma_inst_enable),

        .dma_sram_region              (dma_sram_region),
        .dma_sram_req_addr            (dma_sram_req_addr),
        .dma_sram_req_data            (dma_sram_req_data),
        .dma_sram_req_write           (dma_sram_req_write),
        .dma_sram_req_valid           (dma_sram_req_valid),
        .dma_sram_req_ready           (dma_sram_req_ready),
        .dma_sram_rsp_data            (dma_sram_rsp_data),
        .dma_sram_rsp_valid           (dma_sram_rsp_valid),
        .dma_sram_rsp_ready           (dma_sram_rsp_ready),

        .busy                         (core_busy),
        .memory_error                 (core_memory_error),
        .synchronize                  (synchronize)
    );

    // ------------------------------------------------------------------
    // DMA Engine
    // ------------------------------------------------------------------

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
