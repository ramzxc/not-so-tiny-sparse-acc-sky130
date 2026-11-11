// TPU system top level.
//
// Responsibilities:
//   * Queue 64-bit host instructions
//   * Connect the instruction core to the DMA and local memories (with explicit weight-buffer preloads)
//   * Expose tensor-memory traffic through one AXI4 master interface
module tpu
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH          = 2,
    parameter int SRAM_BYTES             = DEFAULT_SRAM_BYTES,
    parameter int WEIGHT_BUFFER_DEPTH    = SRAM_BYTES / 16,
    parameter int UNIFIED_BUFFER_DEPTH   = SRAM_BYTES / 8,
    parameter int AXI_DATA_BYTES         = 8,
    parameter int AXI_ID_WIDTH           = 4,
    parameter int REGISTER_DEPTH         = SRAM_BYTES / 16
)(
    input logic clk,
    input logic rst,

    // ------------------------------------------------------------------
    // HOST -> TPU core (instruction)
    // ------------------------------------------------------------------
    input inst_type inst_word,
    input logic     inst_write_enable,
    output logic    inst_fifo_empty,
    output logic    inst_fifo_full,

    // ------------------------------------------------------------------
    // AXI4 <-> TPU core
    // ------------------------------------------------------------------
    // AXI4 master write-address channel.
    output logic [AXI_ID_WIDTH-1:0]                  m_axi_awid,
    output dram_addr_type                            m_axi_awaddr,
    output logic [7:0]                              m_axi_awlen,
    output logic [2:0]                              m_axi_awsize,
    output logic [1:0]                              m_axi_awburst,
    output logic                                    m_axi_awlock,
    output logic [3:0]                              m_axi_awcache,
    output logic [2:0]                              m_axi_awprot,
    output logic [3:0]                              m_axi_awqos,
    output logic [3:0]                              m_axi_awregion,
    output logic                                    m_axi_awvalid,
    input  logic                                    m_axi_awready,

    // AXI4 master write-data channel.
    output logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]    m_axi_wdata,
    output logic [AXI_DATA_BYTES-1:0]               m_axi_wstrb,
    output logic                                    m_axi_wlast,
    output logic                                    m_axi_wvalid,
    input  logic                                    m_axi_wready,

    // AXI4 master write-response channel.
    input  logic [AXI_ID_WIDTH-1:0]                  m_axi_bid,
    input  logic [1:0]                              m_axi_bresp,
    input  logic                                    m_axi_bvalid,
    output logic                                    m_axi_bready,

    // AXI4 master read-address channel.
    output logic [AXI_ID_WIDTH-1:0]                  m_axi_arid,
    output dram_addr_type                            m_axi_araddr,
    output logic [7:0]                              m_axi_arlen,
    output logic [2:0]                              m_axi_arsize,
    output logic [1:0]                              m_axi_arburst,
    output logic                                    m_axi_arlock,
    output logic [3:0]                              m_axi_arcache,
    output logic [2:0]                              m_axi_arprot,
    output logic [3:0]                              m_axi_arqos,
    output logic [3:0]                              m_axi_arregion,
    output logic                                    m_axi_arvalid,
    input  logic                                    m_axi_arready,

    // AXI4 master read-data channel.
    input  logic [AXI_ID_WIDTH-1:0]                  m_axi_rid,
    input  logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]    m_axi_rdata,
    input  logic [1:0]                              m_axi_rresp,
    input  logic                                    m_axi_rlast,
    input  logic                                    m_axi_rvalid,
    output logic                                    m_axi_rready,

    output logic axi_error,

    // synchronize done
    output logic synchronize
);

    // ------------------------------------------------------------------
    // Instruction FIFO -> TPU core
    // ------------------------------------------------------------------

    inst_type inst;
    logic inst_pop;
    logic core_busy;
    logic memory_error, adapter_error;
    assign axi_error = memory_error || adapter_error;

    // ------------------------------------------------------------------
    // TPU core <-> DMA command/status interface
    // ------------------------------------------------------------------

    dram_inst_type dma_inst;
    logic          dma_inst_enable;
    logic dma_busy;
    logic dma_weight_resource_busy;
    logic dma_buffer_resource_busy;
    logic dma_acc_resource_busy;

    weight_addr_type dma_weight_write_addr;
    fp16_type [COMPUTE_WIDTH-1:0] dma_weight_write_data;
    logic dma_weight_write_valid, dma_weight_write_ready;

    // ------------------------------------------------------------------
    // DMA <-> local memories inside TPU core (UB & ACC)
    // ------------------------------------------------------------------

    buffer_addr_type              dma_buffer_write_addr;
    fp16_type [COMPUTE_WIDTH-1:0] dma_buffer_write_data;
    logic                         dma_buffer_write_valid;
    logic                         dma_buffer_write_ready;

    buffer_addr_type              dma_buffer_read_req_addr;
    logic                         dma_buffer_read_req_valid;
    logic                         dma_buffer_read_req_ready;
    fp16_type [COMPUTE_WIDTH-1:0] dma_buffer_read_rsp_data;
    logic                         dma_buffer_read_rsp_valid;
    logic                         dma_buffer_read_rsp_ready;

    accumulator_addr_type         dma_acc_read_req_addr;
    logic                         dma_acc_read_req_valid;
    logic                         dma_acc_read_req_ready;
    fp16_type [COMPUTE_WIDTH-1:0] dma_acc_read_rsp_data;
    logic                         dma_acc_read_rsp_valid;
    logic                         dma_acc_read_rsp_ready;

    accumulator_addr_type         dma_acc_write_addr;
    fp16_type [COMPUTE_WIDTH-1:0] dma_acc_write_data;
    logic                         dma_acc_write_valid;
    logic                         dma_acc_write_ready;

    // ------------------------------------------------------------------
    // DMA <-> AXI adapter channels
    // ------------------------------------------------------------------

    dram_addr_type                            dma_read_cmd_addr;
    logic [7:0]                               dma_read_cmd_len;
    logic                                     dma_read_cmd_valid;
    logic                                     dma_read_cmd_ready;
    logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]     dma_read_data;
    logic                                     dma_read_data_last;
    logic                                     dma_read_data_valid;
    logic                                     dma_read_data_ready;

    dram_addr_type                            dma_write_cmd_addr;
    logic [7:0]                               dma_write_cmd_len;
    logic                                     dma_write_cmd_valid;
    logic                                     dma_write_cmd_ready;
    logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]     dma_write_data;
    logic [AXI_DATA_BYTES-1:0]                 dma_write_strb;
    logic                                     dma_write_data_last;
    logic                                     dma_write_data_valid;
    logic                                     dma_write_data_ready;
    logic                                     dma_write_rsp_valid;
    logic                                     dma_write_rsp_ready;

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
        .dma_weight_resource_busy     (dma_weight_resource_busy),
        .dma_buffer_resource_busy     (dma_buffer_resource_busy),
        .dma_acc_resource_busy        (dma_acc_resource_busy),
        .dma_inst                     (dma_inst),
        .dma_inst_enable              (dma_inst_enable),

        .dma_weight_write_addr(dma_weight_write_addr),
        .dma_weight_write_data(dma_weight_write_data),
        .dma_weight_write_valid(dma_weight_write_valid),
        .dma_weight_write_ready(dma_weight_write_ready),

        // Unified Buffer Ports
        .dma_buffer_write_addr        (dma_buffer_write_addr),
        .dma_buffer_write_data        (dma_buffer_write_data),
        .dma_buffer_write_valid       (dma_buffer_write_valid),
        .dma_buffer_write_ready       (dma_buffer_write_ready),
        .dma_buffer_read_req_addr     (dma_buffer_read_req_addr),
        .dma_buffer_read_req_valid    (dma_buffer_read_req_valid),
        .dma_buffer_read_req_ready    (dma_buffer_read_req_ready),
        .dma_buffer_read_rsp_data     (dma_buffer_read_rsp_data),
        .dma_buffer_read_rsp_valid    (dma_buffer_read_rsp_valid),
        .dma_buffer_read_rsp_ready    (dma_buffer_read_rsp_ready),

        // Accumulation Buffer Ports
        .dma_acc_read_req_addr        (dma_acc_read_req_addr),
        .dma_acc_read_req_valid       (dma_acc_read_req_valid),
        .dma_acc_read_req_ready       (dma_acc_read_req_ready),
        .dma_acc_read_rsp_data        (dma_acc_read_rsp_data),
        .dma_acc_read_rsp_valid       (dma_acc_read_rsp_valid),
        .dma_acc_read_rsp_ready       (dma_acc_read_rsp_ready),
        .dma_acc_write_addr           (dma_acc_write_addr),
        .dma_acc_write_data           (dma_acc_write_data),
        .dma_acc_write_valid          (dma_acc_write_valid),
        .dma_acc_write_ready          (dma_acc_write_ready),

        .busy                         (core_busy),
        .memory_error                 (memory_error),
        .synchronize                  (synchronize)
    );

    // ------------------------------------------------------------------
    // DMA Engine
    // ------------------------------------------------------------------

    dma #(
        .COMPUTE_WIDTH   (COMPUTE_WIDTH),
        .DRAM_DATA_BYTES (AXI_DATA_BYTES)
    ) dma_engine (
        .clk                   (clk),
        .rst                   (rst),
        .inst                  (dma_inst),
        .inst_enable           (dma_inst_enable),
        .busy                  (dma_busy),
        .weight_resource_busy  (dma_weight_resource_busy),
        .buffer_resource_busy  (dma_buffer_resource_busy),
        .acc_resource_busy     (dma_acc_resource_busy),

        .weight_write_addr(dma_weight_write_addr),
        .weight_write_data(dma_weight_write_data),
        .weight_write_valid(dma_weight_write_valid),
        .weight_write_ready(dma_weight_write_ready),

        // DRAM AXI Channels
        .dram_read_cmd_addr    (dma_read_cmd_addr),
        .dram_read_cmd_len     (dma_read_cmd_len),
        .dram_read_cmd_valid   (dma_read_cmd_valid),
        .dram_read_cmd_ready   (dma_read_cmd_ready),
        .dram_read_data        (dma_read_data),
        .dram_read_data_last   (dma_read_data_last),
        .dram_read_data_valid  (dma_read_data_valid),
        .dram_read_data_ready  (dma_read_data_ready),
        .dram_write_cmd_addr   (dma_write_cmd_addr),
        .dram_write_cmd_len    (dma_write_cmd_len),
        .dram_write_cmd_valid  (dma_write_cmd_valid),
        .dram_write_cmd_ready  (dma_write_cmd_ready),
        .dram_write_data       (dma_write_data),
        .dram_write_strb       (dma_write_strb),
        .dram_write_data_last  (dma_write_data_last),
        .dram_write_data_valid (dma_write_data_valid),
        .dram_write_data_ready (dma_write_data_ready),
        .dram_write_rsp_valid  (dma_write_rsp_valid),
        .dram_write_rsp_ready  (dma_write_rsp_ready),

        // Buffer & Accumulator Ports
        .buffer_write_addr     (dma_buffer_write_addr),
        .buffer_write_data     (dma_buffer_write_data),
        .buffer_write_valid    (dma_buffer_write_valid),
        .buffer_write_ready    (dma_buffer_write_ready),
        .buffer_read_req_addr  (dma_buffer_read_req_addr),
        .buffer_read_req_valid (dma_buffer_read_req_valid),
        .buffer_read_req_ready (dma_buffer_read_req_ready),
        .buffer_read_rsp_data  (dma_buffer_read_rsp_data),
        .buffer_read_rsp_valid (dma_buffer_read_rsp_valid),
        .buffer_read_rsp_ready (dma_buffer_read_rsp_ready),
        .acc_read_req_addr     (dma_acc_read_req_addr),
        .acc_read_req_valid    (dma_acc_read_req_valid),
        .acc_read_req_ready    (dma_acc_read_req_ready),
        .acc_read_rsp_data     (dma_acc_read_rsp_data),
        .acc_read_rsp_valid    (dma_acc_read_rsp_valid),
        .acc_read_rsp_ready    (dma_acc_read_rsp_ready),
        .acc_write_addr        (dma_acc_write_addr),
        .acc_write_data        (dma_acc_write_data),
        .acc_write_valid       (dma_acc_write_valid),
        .acc_write_ready       (dma_acc_write_ready)
    );

    // ------------------------------------------------------------------
    // AXI protocol adapter
    // ------------------------------------------------------------------

    axi_master_adapter #(
        .AXI_DATA_BYTES (AXI_DATA_BYTES),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH)
    ) axi_adapter (
        .clk                  (clk),
        .rst                  (rst),
        .dma_read_cmd_addr    (dma_read_cmd_addr),
        .dma_read_cmd_len     (dma_read_cmd_len),
        .dma_read_cmd_valid   (dma_read_cmd_valid),
        .dma_read_cmd_ready   (dma_read_cmd_ready),
        .dma_read_data        (dma_read_data),
        .dma_read_data_last   (dma_read_data_last),
        .dma_read_data_valid  (dma_read_data_valid),
        .dma_read_data_ready  (dma_read_data_ready),
        .dma_write_cmd_addr   (dma_write_cmd_addr),
        .dma_write_cmd_len    (dma_write_cmd_len),
        .dma_write_cmd_valid  (dma_write_cmd_valid),
        .dma_write_cmd_ready  (dma_write_cmd_ready),
        .dma_write_data       (dma_write_data),
        .dma_write_strb       (dma_write_strb),
        .dma_write_data_last  (dma_write_data_last),
        .dma_write_data_valid (dma_write_data_valid),
        .dma_write_data_ready (dma_write_data_ready),
        .dma_write_rsp_valid  (dma_write_rsp_valid),
        .dma_write_rsp_ready  (dma_write_rsp_ready),
        .error                (adapter_error),
        .m_axi_awid           (m_axi_awid),
        .m_axi_awaddr         (m_axi_awaddr),
        .m_axi_awlen          (m_axi_awlen),
        .m_axi_awsize         (m_axi_awsize),
        .m_axi_awburst        (m_axi_awburst),
        .m_axi_awlock         (m_axi_awlock),
        .m_axi_awcache        (m_axi_awcache),
        .m_axi_awprot         (m_axi_awprot),
        .m_axi_awqos          (m_axi_awqos),
        .m_axi_awregion       (m_axi_awregion),
        .m_axi_awvalid        (m_axi_awvalid),
        .m_axi_awready        (m_axi_awready),
        .m_axi_wdata          (m_axi_wdata),
        .m_axi_wstrb          (m_axi_wstrb),
        .m_axi_wlast          (m_axi_wlast),
        .m_axi_wvalid         (m_axi_wvalid),
        .m_axi_wready         (m_axi_wready),
        .m_axi_bid            (m_axi_bid),
        .m_axi_bresp          (m_axi_bresp),
        .m_axi_bvalid         (m_axi_bvalid),
        .m_axi_bready         (m_axi_bready),
        .m_axi_arid           (m_axi_arid),
        .m_axi_araddr         (m_axi_araddr),
        .m_axi_arlen          (m_axi_arlen),
        .m_axi_arsize         (m_axi_arsize),
        .m_axi_arburst        (m_axi_arburst),
        .m_axi_arlock         (m_axi_arlock),
        .m_axi_arcache        (m_axi_arcache),
        .m_axi_arprot         (m_axi_arprot),
        .m_axi_arqos          (m_axi_arqos),
        .m_axi_arregion       (m_axi_arregion),
        .m_axi_arvalid        (m_axi_arvalid),
        .m_axi_arready        (m_axi_arready),
        .m_axi_rid            (m_axi_rid),
        .m_axi_rdata          (m_axi_rdata),
        .m_axi_rresp          (m_axi_rresp),
        .m_axi_rlast          (m_axi_rlast),
        .m_axi_rvalid         (m_axi_rvalid),
        .m_axi_rready         (m_axi_rready)
    );

endmodule
