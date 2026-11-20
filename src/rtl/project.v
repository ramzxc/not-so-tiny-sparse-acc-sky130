/* Copyright (c) 2024 Aram Yun. SPDX-License-Identifier: Apache-2.0 */
`include "defs/defs.vh"
`include "defs/mem_defs.vh"
`default_nettype none

module acc_hard_macro #(parameter integer UART_CLKS_PER_BIT = 87, parameter integer QUEUE_SLOT_BITS=14) (
    input  wire uart_rx_i,
    output wire [7:0] uo_out,
    input  wire [3:0] qspi_dq_i,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire clk,
    input  wire rst_n
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync;
    wire core_rst_n = reset_sync[1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_sync <= 0;
        else        reset_sync <= {reset_sync[0], 1'b1};
    end

    wire tx, uart_credit_ready, rx_inst_val;
    wire host_error,host_busy,input_write,uart_error;
    wire frontend_credit_ready,frontend_rx_valid,queue_error,stream_mode;
    wire [15:0] frontend_rx_word;
    wire stream_start;
    wire [7:0] frame_words;
    wire queue_valid,queue_write,queue_ready,queue_done,queue_byte_valid;
    wire [22:0] queue_addr;
    wire [15:0] queue_data;
    wire [9:0] input_addr;
    wire [15:0] input_data;
    wire fetch_valid,fetch_ready,fetch_done,fetch_byte_valid;
    wire [22:0] fetch_addr;
    wire [3:0] fetch_bytes;
    wire bus_busy;
    wire [`INST_WIDTH-1:0] rx_inst, sequenced_inst;
    wire sequenced_valid, sequenced_ready, micro_error, micro_busy;
    wire [15:0] dispatched_inst;
    wire dispatched_valid, dispatched_ready;
    wire dma_busy, dma_error, dma_read;
    wire [23:0] dma_addr;
    wire [9:0] dma_destination;
    wire [2:0] dma_vectors;
    wire copy_done;
    wire [3:0] qspi_bytes;
    wire [1:0] loaded_input_zero_mask;
    wire [`EXEC_INST_WIDTH-1:0] exec_inst;
    wire [`DATA_INST_WIDTH-1:0] data_inst;
    wire exec_inst_val, data_inst_val, exec_rdy, data_rdy;
    wire [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] operand, result;
    wire operand_val, operand_is_weight, result_val;
    wire input_scalar_mode, input_select, input_sparse;
    wire mem_rdy, read_en, write_en, read_data_val, write_accumulate, memory_error;
    wire [`MEM_ADDR_WIDTH-1:0] addr;
    wire [`MEM_DEVICE_WIDTH-1:0] device;
    wire [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] write_data, read_data;
    wire qspi_req_val, qspi_req_rdy, qspi_req_write, qspi_byte_valid,qspi_done;
    wire [22:0] qspi_addr;
    wire [15:0] qspi_write_data;
    wire [7:0] qspi_read_data;
    wire sck,ram_a_cs;
    wire [3:0] dq_out, dq_oe;

    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) receiver (
        .clk(clk), .rst_n(core_rst_n), .rx(uart_rx_i),
        .inst(rx_inst), .inst_val(rx_inst_val),.error(uart_error)
    );
    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) transmitter (
        .clk(clk), .rst_n(core_rst_n), .credit_ready(uart_credit_ready), .tx(tx)
    );
    input_queue #(.SLOT_BITS(QUEUE_SLOT_BITS)) ingress (
        .clk(clk),.rst_n(core_rst_n),.rx_word(rx_inst),.rx_valid(rx_inst_val),
        .credit_ready(uart_credit_ready),.stream_mode(stream_mode),.error(queue_error),
        .frontend_word(frontend_rx_word),.frontend_valid(frontend_rx_valid),.frontend_credit_ready(frontend_credit_ready),
        .stream_start(stream_start),.frame_words(frame_words),
        .req_valid(queue_valid),.req_write(queue_write),.req_addr(queue_addr),.req_data(queue_data),
        .req_ready(queue_ready),.req_done(queue_done),.req_byte_valid(queue_byte_valid),.req_rdata(qspi_read_data)
    );
    command_ctrl command (
        .clk(clk),
        .rst_n(core_rst_n),
        .frontend_rx_word(frontend_rx_word),
        .frontend_rx_valid(frontend_rx_valid),
        .frontend_credit_ready(frontend_credit_ready),
        .stream_start(stream_start),
        .frame_words(frame_words),
        .host_error(host_error),
        .host_busy(host_busy),
        .micro_error(micro_error),
        .micro_busy(micro_busy),
        .bus_busy(bus_busy),
        .uart_error(uart_error),
        .addr(addr),
        .loaded_input_zero_mask(loaded_input_zero_mask),
        .sequenced_inst(sequenced_inst),
        .sequenced_valid(sequenced_valid),
        .sequenced_ready(sequenced_ready),
        .fetch_valid(fetch_valid),
        .fetch_addr(fetch_addr),
        .fetch_bytes(fetch_bytes),
        .fetch_ready(fetch_ready),
        .fetch_done(fetch_done),
        .fetch_byte_valid(fetch_byte_valid),
        .qspi_read_data(qspi_read_data),
        .input_write(input_write),
        .input_addr(input_addr),
        .input_data(input_data),
        .mem_rdy(mem_rdy),
        .units_idle(exec_rdy && data_rdy && !dma_busy),
        .memory_error(memory_error | dma_error)
    );
    dma_ctrl dma (
        .clk(clk), .rst_n(core_rst_n),
        .host_inst(sequenced_inst), .host_valid(sequenced_valid), .host_ready(sequenced_ready),
        .core_inst(dispatched_inst), .core_valid(dispatched_valid), .core_ready(dispatched_ready),
        .units_idle(exec_rdy && data_rdy), .staging_addr(addr),
        .mem_ready(mem_rdy), .mem_read_valid(copy_done), .memory_error(memory_error),
        .mem_read(dma_read), .mem_addr(dma_addr),
        .mem_destination(dma_destination),.mem_vectors(dma_vectors),
        .busy(dma_busy), .error(dma_error)
    );
    inst_decoder decode (
        .rst_n(core_rst_n), .inst_in(dispatched_inst), .inst_in_val(dispatched_valid),
        .decoder_rdy(dispatched_ready), .exec_rdy(exec_rdy), .data_rdy(data_rdy),
        .exec_inst_out(exec_inst), .exec_inst_out_val(exec_inst_val),
        .data_inst_out(data_inst), .data_inst_out_val(data_inst_val)
    );
    data_ctrl data (
        .clk(clk), .rst_n(core_rst_n),
        .data_inst_in(data_inst), .data_inst_in_val(data_inst_val), .data_rdy(data_rdy),
        .exec_data_in(result), .exec_data_in_val(result_val),
        .exec_data_out(operand), .exec_data_out_val(operand_val),
        .exec_data_is_weight(operand_is_weight),
        .loaded_input_zero_mask(loaded_input_zero_mask),
        .input_scalar_mode(input_scalar_mode), .input_select(input_select), .input_sparse(input_sparse),
        .mem_itf_rdy(mem_rdy && !dma_busy && !input_write), .read_en(read_en), .write_en(write_en),
        .addr(addr), .device(device), .write_accumulate(write_accumulate), .write_data(write_data),
        .read_data(read_data), .read_data_val(read_data_val && !dma_busy)
    );
    exec_unit exec (
        .clk(clk), .rst_n(core_rst_n),
        .exec_inst_in(exec_inst), .exec_inst_in_val(exec_inst_val), .exec_rdy(exec_rdy),
        .data_in(operand), .data_in_val(operand_val), .is_weight(operand_is_weight),
        .input_scalar_mode(input_scalar_mode), .input_select(input_select), .input_sparse(input_sparse),
        .data_out(result), .data_out_val(result_val)
    );
    mem_itf itf (
        .clk(clk), .rst_n(core_rst_n), .rdy(mem_rdy),
        .read_en(!dma_busy && read_en), .write_en(input_write || (!dma_busy && write_en)),
        .copy_en(dma_read),.copy_source(dma_addr),.copy_destination(dma_destination),
        .copy_vectors(dma_vectors),.copy_done(copy_done),
        .write_accumulate(!input_write && !dma_busy && write_accumulate),
        .error(memory_error), .addr(input_write ? {14'b0,input_addr} : addr),
        .device(input_write ? `MEM_SRAM : device),
        // Ordinary writes use DATA or UART; DMA copies through the row buffer.
        .write_data(input_write ? input_data : write_data), .read_data(read_data), .read_data_val(read_data_val),
        .qspi_req_val(qspi_req_val), .qspi_req_rdy(qspi_req_rdy),
        .qspi_req_write(qspi_req_write), .qspi_req_addr(qspi_addr),.qspi_req_bytes(qspi_bytes),
        .qspi_req_data(qspi_write_data),.qspi_read_data(qspi_read_data),
        .qspi_byte_valid(qspi_byte_valid),.qspi_done(qspi_done)
    );
    qspi_ctrl psram (
        .clk(clk),
        .rst_n(core_rst_n),
        .queue_valid(queue_valid),
        .queue_write(queue_write),
        .queue_addr(queue_addr),
        .queue_data(queue_data),
        .queue_ready(queue_ready),
        .queue_done(queue_done),
        .queue_byte_valid(queue_byte_valid),
        .qspi_req_val(qspi_req_val),
        .qspi_req_write(qspi_req_write),
        .qspi_addr(qspi_addr),
        .qspi_bytes(qspi_bytes),
        .qspi_write_data(qspi_write_data),
        .qspi_req_rdy(qspi_req_rdy),
        .qspi_done(qspi_done),
        .qspi_byte_valid(qspi_byte_valid),
        .fetch_valid(fetch_valid),
        .fetch_addr(fetch_addr),
        .fetch_bytes(fetch_bytes),
        .fetch_ready(fetch_ready),
        .fetch_done(fetch_done),
        .fetch_byte_valid(fetch_byte_valid),
        .bus_busy(bus_busy),
        .qspi_read_data(qspi_read_data),
        .qspi_dq_i(qspi_dq_i),
        .sck(sck),
        .ram_a_cs(ram_a_cs),
        .dq_out(dq_out),
        .dq_oe(dq_oe)
    );

    // TinyQV Pmod order, preserved from the original wrapper.
    assign uio_out = {1'b1,ram_a_cs,dq_out[3:2],sck,dq_out[1:0],1'b1};
    assign uio_oe = core_rst_n && rst_n ? {2'b11,dq_oe[3:2],1'b1,dq_oe[1:0],1'b1} : 8'b0;
    assign uo_out  = {3'b0, tx, 1'b0,stream_mode, (memory_error | micro_error | dma_error | host_error | uart_error | queue_error), !host_busy};
endmodule
`default_nettype wire
