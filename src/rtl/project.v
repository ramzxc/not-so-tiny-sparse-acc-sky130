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

    wire tx, fifo_rdy, rx_inst_val, inst_val, decoder_rdy;
    wire host_error,host_busy,input_write,uart_error;
    wire frontend_ready,frontend_rx_valid,queue_error,stream_mode;
    wire [15:0] frontend_rx_word;
    wire queue_valid,queue_write,queue_ready,queue_done,queue_byte_valid;
    wire [22:0] queue_addr;
    wire [15:0] queue_data;
    wire core_bus_ready,core_bus_done,core_bus_byte_valid,queue_bus_busy;
    wire serial_valid,serial_write;
    wire [22:0] serial_addr;
    wire [3:0] serial_bytes;
    wire [15:0] serial_data;
    wire [9:0] input_addr;
    wire [15:0] input_data;
    wire fetch_valid,fetch_ready,fetch_done,fetch_byte_valid;
    wire [22:0] fetch_addr;
    wire [3:0] fetch_bytes;
    wire bus_busy, bus_valid,bus_ready,bus_write,bus_done,bus_byte_valid;
    wire [22:0] bus_addr;
    wire [3:0] bus_bytes;
    wire [15:0] bus_data;
    wire [`INST_WIDTH-1:0] rx_inst, inst, sequenced_inst;
    wire sequenced_valid, sequenced_ready, micro_error, micro_busy;
    wire [15:0] dispatched_inst;
    wire dispatched_valid, dispatched_ready;
    wire dma_busy, dma_error, dma_read, dma_write, dma_read_continue;
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
    wire [`MEM_DEVICE_WIDTH-1:0] qspi_device;
    wire [15:0] qspi_write_data;
    wire [7:0] qspi_read_data;
    wire sck,ram_a_cs;
    wire [3:0] dq_out, dq_oe;

    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) receiver (
        .clk(clk), .rst_n(core_rst_n), .rx(uart_rx_i),
        .inst(rx_inst), .inst_val(rx_inst_val),.error(uart_error)
    );
    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) transmitter (
        .clk(clk), .rst_n(core_rst_n), .inst_fifo_rdy(fifo_rdy), .tx(tx)
    );
    uart_psram_queue #(.SLOT_BITS(QUEUE_SLOT_BITS)) ingress (
        .clk(clk),.rst_n(core_rst_n),.rx_word(rx_inst),.rx_valid(rx_inst_val),
        .rx_ready(fifo_rdy),.stream_mode(stream_mode),.error(queue_error),
        .frontend_word(frontend_rx_word),.frontend_valid(frontend_rx_valid),.frontend_ready(frontend_ready),
        .req_valid(queue_valid),.req_write(queue_write),.req_addr(queue_addr),.req_data(queue_data),
        .req_ready(queue_ready),.req_done(queue_done),.req_byte_valid(queue_byte_valid),.req_rdata(qspi_read_data)
    );
    program_ctrl frontend (
        .clk(clk),.rst_n(core_rst_n),.rx_word(frontend_rx_word),.rx_valid(frontend_rx_valid),
        .rx_ready(frontend_ready),.error(host_error),.busy(host_busy),
        .units_idle(exec_rdy && data_rdy && !dma_busy && !micro_busy && !bus_busy),
        .memory_error(memory_error | dma_error | micro_error | uart_error),
        .inst(inst),.inst_valid(inst_val),.inst_ready(decoder_rdy),
        .fetch_valid(fetch_valid),.fetch_addr(fetch_addr),.fetch_bytes(fetch_bytes),
        .fetch_ready(fetch_ready),.fetch_done(fetch_done),.fetch_data(qspi_read_data),
        .fetch_byte_valid(fetch_byte_valid),
        .input_write(input_write),.input_addr(input_addr),.input_data(input_data),.mem_ready(mem_rdy)
    );
    micro_ctrl sequencer (
        .clk(clk), .rst_n(core_rst_n), .host_inst(inst), .host_valid(inst_val),
        .host_ready(decoder_rdy), .core_inst(sequenced_inst), .core_valid(sequenced_valid),
        .core_ready(sequenced_ready), .units_idle(exec_rdy && data_rdy && !dma_busy),
        .staging_addr(addr), .input_zero_mask(loaded_input_zero_mask),
        .memory_error(memory_error | dma_error), .busy(micro_busy), .error(micro_error)
    );
    dma_ctrl dma (
        .clk(clk), .rst_n(core_rst_n),
        .host_inst(sequenced_inst), .host_valid(sequenced_valid), .host_ready(sequenced_ready),
        .core_inst(dispatched_inst), .core_valid(dispatched_valid), .core_ready(dispatched_ready),
        .units_idle(exec_rdy && data_rdy), .staging_addr(addr),
        .mem_ready(mem_rdy), .mem_read_valid(copy_done), .memory_error(memory_error),
        .mem_read(dma_read), .mem_write(dma_write), .mem_addr(dma_addr),
        .mem_read_continue(dma_read_continue),.mem_destination(dma_destination),.mem_vectors(dma_vectors),
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
        .read_burst(dma_busy), .read_continue(dma_read_continue),
        .error(memory_error), .addr(input_write ? {14'b0,input_addr} : addr),
        .device(input_write ? `MEM_SRAM : device),
        // Ordinary writes use DATA or UART; DMA copies through the row buffer.
        .write_data(input_write ? input_data : write_data), .read_data(read_data), .read_data_val(read_data_val),
        .qspi_req_val(qspi_req_val), .qspi_req_rdy(qspi_req_rdy),
        .qspi_req_write(qspi_req_write), .qspi_req_addr(qspi_addr),.qspi_req_bytes(qspi_bytes),
        .qspi_req_data(qspi_write_data),.qspi_read_data(qspi_read_data),
        .qspi_byte_valid(qspi_byte_valid),.qspi_done(qspi_done)
    );
    psram_arbiter memory_owner (
        .clk(clk),.rst_n(core_rst_n),
        .data_valid(qspi_req_val),.data_write(qspi_req_write),.data_addr(qspi_addr),
        .data_bytes(qspi_bytes),.data_wdata(qspi_write_data),.data_ready(qspi_req_rdy),
        .data_done(qspi_done),.data_byte_valid(qspi_byte_valid),
        .fetch_valid(fetch_valid),.fetch_addr(fetch_addr),.fetch_bytes(fetch_bytes),
        .fetch_write(1'b0),.fetch_wdata(16'b0),
        .fetch_ready(fetch_ready),.fetch_done(fetch_done),.fetch_byte_valid(fetch_byte_valid),
        .req_valid(bus_valid),.req_write(bus_write),.req_addr(bus_addr),.req_bytes(bus_bytes),
        .req_data(bus_data),.req_ready(core_bus_ready),.done(core_bus_done),.byte_valid(core_bus_byte_valid),.busy(bus_busy)
    );
    // Existing arbiter owns the core request; a second transaction arbiter
    // grants sparse UART queue traffic priority without interrupting a burst.
    psram_arbiter #(.FETCH_WRITES(1)) ingress_owner (
        .clk(clk),.rst_n(core_rst_n),
        .data_valid(queue_valid),.data_write(queue_write),.data_addr(queue_addr),
        .data_bytes(4'd2),.data_wdata(queue_data),.data_ready(queue_ready),
        .data_done(queue_done),.data_byte_valid(queue_byte_valid),
        .fetch_valid(bus_valid),.fetch_addr(bus_addr),.fetch_bytes(bus_bytes),
        .fetch_write(bus_write),.fetch_wdata(bus_data),
        .fetch_ready(core_bus_ready),.fetch_done(core_bus_done),.fetch_byte_valid(core_bus_byte_valid),
        .req_valid(serial_valid),.req_write(serial_write),.req_addr(serial_addr),.req_bytes(serial_bytes),
        .req_data(serial_data),.req_ready(bus_ready),.done(bus_done),.byte_valid(bus_byte_valid),.busy(queue_bus_busy)
    );
    qspi_ctrl serial_memory (
        .clk(clk),.rst_n(core_rst_n),.req_valid(serial_valid),.req_ready(bus_ready),
        .req_write(serial_write),.req_addr(serial_addr),.req_bytes(serial_bytes),.req_data(serial_data),
        .read_data(qspi_read_data),.byte_valid(bus_byte_valid),.done(bus_done),
        .sck(sck),.cs_n(ram_a_cs),.dq_in(qspi_dq_i),.dq_out(dq_out),.dq_oe(dq_oe)
    );

    // TinyQV Pmod order, preserved from the original wrapper.
    assign uio_out = {1'b1,ram_a_cs,dq_out[3:2],sck,dq_out[1:0],1'b1};
    assign uio_oe = core_rst_n && rst_n ? {2'b11,dq_oe[3:2],1'b1,dq_oe[1:0],1'b1} : 8'b0;
    assign uo_out  = {3'b0, tx, 1'b0,stream_mode, (memory_error | micro_error | dma_error | host_error | uart_error | queue_error), !host_busy};
    wire _unused = &{micro_busy,dma_write,1'b0};
endmodule
`default_nettype wire
