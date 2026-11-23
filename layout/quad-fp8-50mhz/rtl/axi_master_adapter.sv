// GPT-generated ;;
// AXI4 master adapter.
//
// Responsibilities:
//   * Convert DMA burst commands into AXI4 AR/AW transactions
//   * Forward AXI4 R data and DMA W data without changing the beat width
//   * Retain every AXI VALID and payload until the matching READY handshake
//   * Check response codes, IDs, LEN, and LAST consistency
//
// One read burst and one write burst may be active at the same time. Each
// direction supports one outstanding burst.
module axi_master_adapter
    import tpu_pkg::*;
#(
    parameter int AXI_DATA_BYTES = 8,
    parameter int AXI_ID_WIDTH   = 4
)(
    input logic clk,
    input logic rst,

    // DMA read-burst command and returned data stream.
    input  dram_addr_type                             dma_read_cmd_addr,
    input  logic [7:0]                                dma_read_cmd_len,
    input  logic                                      dma_read_cmd_valid,
    output logic                                      dma_read_cmd_ready,
    output logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]      dma_read_data,
    output logic                                      dma_read_data_last,
    output logic                                      dma_read_data_valid,
    input  logic                                      dma_read_data_ready,

    // DMA write-burst command, data stream, and completion response.
    input  dram_addr_type                             dma_write_cmd_addr,
    input  logic [7:0]                                dma_write_cmd_len,
    input  logic                                      dma_write_cmd_valid,
    output logic                                      dma_write_cmd_ready,
    input  logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]      dma_write_data,
    input  logic [AXI_DATA_BYTES-1:0]                 dma_write_strb,
    input  logic                                      dma_write_data_last,
    input  logic                                      dma_write_data_valid,
    output logic                                      dma_write_data_ready,
    output logic                                      dma_write_rsp_valid,
    input  logic                                      dma_write_rsp_ready,

    // Sticky indication of an AXI error response or protocol mismatch.
    output logic                                      error,

    // AXI4 write-address channel.
    output logic [AXI_ID_WIDTH-1:0]                   m_axi_awid,
    output dram_addr_type                             m_axi_awaddr,
    output logic [7:0]                                m_axi_awlen,
    output logic [2:0]                                m_axi_awsize,
    output logic [1:0]                                m_axi_awburst,
    output logic                                      m_axi_awlock,
    output logic [3:0]                                m_axi_awcache,
    output logic [2:0]                                m_axi_awprot,
    output logic [3:0]                                m_axi_awqos,
    output logic [3:0]                                m_axi_awregion,
    output logic                                      m_axi_awvalid,
    input  logic                                      m_axi_awready,

    // AXI4 write-data channel.
    output logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]      m_axi_wdata,
    output logic [AXI_DATA_BYTES-1:0]                 m_axi_wstrb,
    output logic                                      m_axi_wlast,
    output logic                                      m_axi_wvalid,
    input  logic                                      m_axi_wready,

    // AXI4 write-response channel.
    input  logic [AXI_ID_WIDTH-1:0]                   m_axi_bid,
    input  logic [1:0]                                m_axi_bresp,
    input  logic                                      m_axi_bvalid,
    output logic                                      m_axi_bready,

    // AXI4 read-address channel.
    output logic [AXI_ID_WIDTH-1:0]                   m_axi_arid,
    output dram_addr_type                             m_axi_araddr,
    output logic [7:0]                                m_axi_arlen,
    output logic [2:0]                                m_axi_arsize,
    output logic [1:0]                                m_axi_arburst,
    output logic                                      m_axi_arlock,
    output logic [3:0]                                m_axi_arcache,
    output logic [2:0]                                m_axi_arprot,
    output logic [3:0]                                m_axi_arqos,
    output logic [3:0]                                m_axi_arregion,
    output logic                                      m_axi_arvalid,
    input  logic                                      m_axi_arready,

    // AXI4 read-data channel.
    input  logic [AXI_ID_WIDTH-1:0]                   m_axi_rid,
    input  logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0]      m_axi_rdata,
    input  logic [1:0]                                m_axi_rresp,
    input  logic                                      m_axi_rlast,
    input  logic                                      m_axi_rvalid,
    output logic                                      m_axi_rready
);

    localparam logic [2:0] AXI_TRANSFER_SIZE = 3'($clog2(AXI_DATA_BYTES));
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [AXI_ID_WIDTH-1:0] DMA_AXI_ID = '0;

    // One read burst is active at a time. The command is retained until the
    // AR handshake, and the burst remains active until its final R beat.
    logic          read_active_cs;
    logic          read_ar_done_cs;
    dram_addr_type read_addr_cs;
    logic [8:0]    read_beats_left_cs;

    // One write burst is active at a time. AW and W remain independent. A
    // one-beat elastic register retains WVALID and its payload across pauses.
    logic          write_active_cs;
    logic          write_aw_done_cs;
    dram_addr_type write_addr_cs;
    logic [8:0]    write_input_beats_left_cs;
    logic [8:0]    write_output_beats_left_cs;

    logic [AXI_DATA_BYTES*BYTE_WIDTH-1:0] write_data_cs;
    logic [AXI_DATA_BYTES-1:0]            write_strb_cs;
    logic                                 write_last_cs;
    logic                                 write_data_valid_cs;

    logic read_cmd_fire;
    logic write_cmd_fire;
    logic write_data_push;
    logic ar_fire;
    logic r_fire;
    logic aw_fire;
    logic w_fire;
    logic b_fire;
    logic write_request_complete;

    assign dma_read_cmd_ready = !read_active_cs;
    assign read_cmd_fire = dma_read_cmd_valid && dma_read_cmd_ready;

    assign m_axi_arid     = DMA_AXI_ID;
    assign m_axi_araddr   = read_addr_cs;
    assign m_axi_arsize   = AXI_TRANSFER_SIZE;
    assign m_axi_arburst  = AXI_BURST_INCR;
    assign m_axi_arlock   = 1'b0;
    assign m_axi_arcache  = 4'b0011;
    assign m_axi_arprot   = 3'b000;
    assign m_axi_arqos    = 4'b0000;
    assign m_axi_arregion = 4'b0000;
    assign m_axi_arvalid  = read_active_cs && !read_ar_done_cs;
    assign ar_fire        = m_axi_arvalid && m_axi_arready;

    assign dma_read_data       = m_axi_rdata;
    assign dma_read_data_last  = m_axi_rlast;
    assign dma_read_data_valid =
        read_active_cs && read_ar_done_cs && m_axi_rvalid;
    assign m_axi_rready =
        read_active_cs && read_ar_done_cs && dma_read_data_ready;
    assign r_fire = m_axi_rvalid && m_axi_rready;

    assign dma_write_cmd_ready = !write_active_cs;
    assign write_cmd_fire = dma_write_cmd_valid && dma_write_cmd_ready;

    assign m_axi_awid     = DMA_AXI_ID;
    assign m_axi_awaddr   = write_addr_cs;
    assign m_axi_awsize   = AXI_TRANSFER_SIZE;
    assign m_axi_awburst  = AXI_BURST_INCR;
    assign m_axi_awlock   = 1'b0;
    assign m_axi_awcache  = 4'b0011;
    assign m_axi_awprot   = 3'b000;
    assign m_axi_awqos    = 4'b0000;
    assign m_axi_awregion = 4'b0000;
    assign m_axi_awvalid  = write_active_cs && !write_aw_done_cs;
    assign aw_fire        = m_axi_awvalid && m_axi_awready;

    assign dma_write_data_ready =
        write_active_cs &&
        (write_input_beats_left_cs != '0) &&
        (!write_data_valid_cs || w_fire);
    assign write_data_push = dma_write_data_valid && dma_write_data_ready;

    assign m_axi_wdata  = write_data_cs;
    assign m_axi_wstrb  = write_strb_cs;
    assign m_axi_wlast  = write_last_cs;
    assign m_axi_wvalid = write_data_valid_cs;
    assign w_fire       = m_axi_wvalid && m_axi_wready;

    assign write_request_complete =
        write_active_cs &&
        write_aw_done_cs &&
        (write_output_beats_left_cs == '0) &&
        !write_data_valid_cs;

    assign dma_write_rsp_valid =
        write_request_complete && m_axi_bvalid;
    assign m_axi_bready =
        write_request_complete && dma_write_rsp_ready;
    assign b_fire = m_axi_bvalid && m_axi_bready;

`ifndef SYNTHESIS
    initial begin
        if (AXI_DATA_BYTES < 1 || AXI_DATA_BYTES > 128 ||
            (AXI_DATA_BYTES & (AXI_DATA_BYTES - 1)) != 0)
            $fatal(1, "axi_master_adapter AXI_DATA_BYTES must be a power of two from 1 to 128");
        if (AXI_ID_WIDTH < 1)
            $fatal(1, "axi_master_adapter AXI_ID_WIDTH must be positive");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            read_active_cs            <= 1'b0;
            read_ar_done_cs           <= 1'b0;
            read_addr_cs              <= '0;
            m_axi_arlen               <= '0;
            read_beats_left_cs        <= '0;

            write_active_cs           <= 1'b0;
            write_aw_done_cs          <= 1'b0;
            write_addr_cs             <= '0;
            m_axi_awlen              <= '0;
            write_input_beats_left_cs <= '0;
            write_output_beats_left_cs<= '0;
            write_data_cs             <= '0;
            write_strb_cs             <= '0;
            write_last_cs             <= 1'b0;
            write_data_valid_cs       <= 1'b0;
            error                     <= 1'b0;
        end
        else begin
            if (read_cmd_fire) begin
                read_active_cs     <= 1'b1;
                read_ar_done_cs    <= 1'b0;
                read_addr_cs       <= dma_read_cmd_addr;
                m_axi_arlen        <= dma_read_cmd_len;
                read_beats_left_cs <= {1'b0, dma_read_cmd_len} + 1'b1;
            end

            if (ar_fire)
                read_ar_done_cs <= 1'b1;

            if (r_fire) begin
                if (m_axi_rresp[1] ||
                    (m_axi_rid != DMA_AXI_ID) ||
                    (m_axi_rlast != (read_beats_left_cs == 1)))
                    error <= 1'b1;

                if (read_beats_left_cs == 1) begin
                    read_active_cs     <= 1'b0;
                    read_ar_done_cs    <= 1'b0;
                    read_beats_left_cs <= '0;
                end
                else begin
                    read_beats_left_cs <= read_beats_left_cs - 1'b1;
                end
            end

            if (write_cmd_fire) begin
                write_active_cs            <= 1'b1;
                write_aw_done_cs           <= 1'b0;
                write_addr_cs              <= dma_write_cmd_addr;
                m_axi_awlen               <= dma_write_cmd_len;
                write_input_beats_left_cs  <=
                    {1'b0, dma_write_cmd_len} + 1'b1;
                write_output_beats_left_cs <=
                    {1'b0, dma_write_cmd_len} + 1'b1;
            end

            if (aw_fire)
                write_aw_done_cs <= 1'b1;

            if (write_data_push) begin
                write_data_cs       <= dma_write_data;
                write_strb_cs       <= dma_write_strb;
                write_last_cs       <= dma_write_data_last;
                write_data_valid_cs <= 1'b1;
                write_input_beats_left_cs <=
                    write_input_beats_left_cs - 1'b1;
            end
            else if (w_fire) begin
                write_data_valid_cs <= 1'b0;
            end

            if (w_fire) begin
                if (write_last_cs != (write_output_beats_left_cs == 1))
                    error <= 1'b1;
                write_output_beats_left_cs <=
                    write_output_beats_left_cs - 1'b1;
            end

            if (b_fire) begin
                if (m_axi_bresp[1] || (m_axi_bid != DMA_AXI_ID))
                    error <= 1'b1;
                write_active_cs  <= 1'b0;
                write_aw_done_cs <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (r_fire &&
                (m_axi_rlast != (read_beats_left_cs == 1)))
                $error("axi_master_adapter RLAST does not match ARLEN");
            if (r_fire && (m_axi_rid != DMA_AXI_ID))
                $error("axi_master_adapter received an unexpected RID");
            if (w_fire &&
                (write_last_cs != (write_output_beats_left_cs == 1)))
                $error("axi_master_adapter WLAST does not match AWLEN");
            if (b_fire && (m_axi_bid != DMA_AXI_ID))
                $error("axi_master_adapter received an unexpected BID");
        end
    end
`endif

endmodule
