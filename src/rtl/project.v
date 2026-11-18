/* Copyright (c) 2024 Aram Yun. SPDX-License-Identifier: Apache-2.0 */
`include "defs/defs.vh"
`include "defs/mem_defs.vh"
`default_nettype none

module acc_hard_macro #(parameter integer UART_CLKS_PER_BIT = 87) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire ena,
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
    wire [`INST_WIDTH-1:0] rx_inst, inst, sequenced_inst;
    wire sequenced_valid, sequenced_ready, micro_error, micro_busy;
    wire [15:0] dispatched_inst;
    wire dispatched_valid, dispatched_ready;
    wire dma_busy, dma_error, dma_read, dma_write;
    wire [23:0] dma_addr;
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
    wire qspi_req_val, qspi_req_rdy, qspi_req_write, qspi_read_data_val;
    wire [`MEM_ADDR_WIDTH-1:0] qspi_addr;
    wire [`MEM_DEVICE_WIDTH-1:0] qspi_device;
    wire [7:0] qspi_write_data, qspi_read_data;
    wire sck, flash_cs, ram_a_cs, ram_b_cs;
    wire [3:0] dq_out, dq_oe;

    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) receiver (
        .clk(clk), .rst_n(core_rst_n), .rx(ui_in[3]),
        .inst(rx_inst), .inst_val(rx_inst_val)
    );
    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) transmitter (
        .clk(clk), .rst_n(core_rst_n), .inst_fifo_rdy(fifo_rdy), .tx(tx)
    );
    inst_fifo #(.FIFO_DEPTH(2)) fifo (
        .clk(clk), .rst_n(core_rst_n),
        .inst_in(rx_inst), .inst_in_val(rx_inst_val), .fifo_rdy(fifo_rdy),
        .decoder_rdy(decoder_rdy), .inst_out(inst), .inst_out_val(inst_val)
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
        .mem_ready(mem_rdy), .mem_read_valid(read_data_val), .memory_error(memory_error),
        .mem_read(dma_read), .mem_write(dma_write), .mem_addr(dma_addr),
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
        .mem_itf_rdy(mem_rdy && !dma_busy), .read_en(read_en), .write_en(write_en),
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
        .read_en(dma_busy ? dma_read : read_en), .write_en(dma_busy ? dma_write : write_en),
        .write_accumulate(!dma_busy && write_accumulate),
        .error(memory_error), .addr(dma_busy ? dma_addr : addr),
        .device(dma_busy ? (dma_write ? `MEM_SRAM : `MEM_FLASH) : device),
        // read_data is held across writes by mem_itf; copy all 32 bits verbatim.
        .write_data(dma_busy ? read_data : write_data), .read_data(read_data), .read_data_val(read_data_val),
        .qspi_req_val(qspi_req_val), .qspi_req_rdy(qspi_req_rdy),
        .qspi_req_write(qspi_req_write), .qspi_req_addr(qspi_addr),
        .qspi_req_device(qspi_device), .qspi_req_data(qspi_write_data),
        .qspi_read_data(qspi_read_data), .qspi_read_data_val(qspi_read_data_val)
    );
    qspi_ctrl serial_memory (
        .clk(clk), .rst_n(core_rst_n),
        .req_val(qspi_req_val), .req_rdy(qspi_req_rdy), .req_write(qspi_req_write),
        .req_addr(qspi_addr), .req_device(qspi_device), .req_data(qspi_write_data),
        .read_data(qspi_read_data), .read_data_val(qspi_read_data_val),
        .sck(sck), .flash_sc_n(flash_cs), .psram_a_sc_n(ram_a_cs), .psram_b_sc_n(ram_b_cs),
        .dq_in({uio_in[5:4], uio_in[2:1]}), .dq_out(dq_out), .dq_oe(dq_oe)
    );

    // TinyQV Pmod order, preserved from the original wrapper.
    assign uio_out = {ram_b_cs, ram_a_cs, dq_out[3:2], sck, dq_out[1:0], flash_cs};
    assign uio_oe  = {2'b11, dq_oe[3:2], 1'b1, dq_oe[1:0], 1'b1};
    assign uo_out  = {3'b0, tx, 2'b0, (memory_error | micro_error | dma_error), decoder_rdy};
    wire _unused = &{ui_in[7:4], ui_in[2:0], uio_in[7:6], uio_in[3], uio_in[0], ena, micro_busy, 1'b0};
endmodule
`default_nettype wire
