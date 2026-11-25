// UART and QPI pins for the weight-stationary FP8 batch experiment.
module accelerator_top #(
    parameter int INGRESS_BYTES = 2
) (
    input wire clk, rst_n, rx,
    input wire [3:0] dq_in,
    output wire [3:0] dq_out, dq_oe,
    output wire tx, sck, cs_n, fault,
    output logic ready
);
    import tpu_pkg::*;
    localparam int SRAM_BYTES = 512;
    localparam int UB_WB_ROWS = 32;
    localparam logic [9:0] UART_DEFAULT_CLKS = 10'd87;
    localparam logic [9:0] UART_MIN_CLKS = 10'd32;
    wire rst = !rst_n;
    wire [63:0] inst_word, fetched_word;
    wire fetch_take, fetch_req, inst_enable, full;
    wire [31:0] dma_cmd_addr;
    wire [7:0] dma_cmd_len, dma_write_strb;
    wire dma_cmd_write, dma_cmd_valid, dma_cmd_ready;
    wire [63:0] dma_rsp_data, dma_write_data;
    wire dma_rsp_valid, dma_rsp_ready;
    wire dma_write_data_valid, dma_write_data_ready;
    wire result_valid, result_ready, fetch_valid;
    wire [31:0] result_data;
    wire [2:0] result_bytes;
    wire [22:0] fetch_addr, input_addr;
    wire [8*INGRESS_BYTES-1:0] input_data;
    wire input_valid, input_ready, input_done, frame_ready;
    wire [2:0] frame_slot;
    wire [3:0] complete_frames;
    logic [2:0] batch_size;
    wire [8:0] available_bytes;
    wire fetch_pair;
    wire uart_fault, synchronized;

    // The board prepares PSRAM in QPI mode and initializes c and y for each lane
    // before reset release. An eight-byte header immediately before the program
    // gives the channel count [8:0], batch size [11:9], and UART clocks per bit
    // [21:12]. A zero UART field selects the legacy default.
    localparam logic [22:0] HEADER_ADDR = 23'h1ffff8;
    logic [8:0] channels;
    logic [9:0] uart_clks_per_bit;
    wire [9:0] header_uart_clks = fetched_word[21:12];
    logic config_fault;
    wire core_fault;
    wire boot = !ready && !config_fault;
    wire memory_fetch_req = boot || (ready && fetch_req);
    wire memory_fetch_take = boot ? fetch_valid : fetch_take;
    wire [22:0] memory_fetch_addr = boot ? HEADER_ADDR : fetch_addr;
    assign fault = core_fault || uart_fault || config_fault;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready <= 0;
            channels <= 0;
            batch_size <= 0;
            uart_clks_per_bit <= UART_DEFAULT_CLKS;
            config_fault <= 0;
        end else if (boot && fetch_valid) begin
            if (fetched_word[63:22] == 0 && fetched_word[8:0] > 0 && fetched_word[8:0] <= 256 &&
                fetched_word[11:9] >= 1 && fetched_word[11:9] <= 4 &&
                (header_uart_clks == 0 || header_uart_clks >= UART_MIN_CLKS)) begin
                channels <= fetched_word[8:0];
                batch_size <= fetched_word[11:9];
                uart_clks_per_bit <= header_uart_clks == 0 ? UART_DEFAULT_CLKS : header_uart_clks;
                ready <= 1;
            end else begin
                config_fault <= 1;
            end
        end
    end

    // Four FP8 elements per row: 128 B UB, 256 B ACC, and 128 B WB.
    tpu #(
        .SRAM_BYTES(SRAM_BYTES), .COMPUTE_WIDTH(4),
        .UNIFIED_BUFFER_DEPTH(UB_WB_ROWS), .REGISTER_DEPTH(64), .WEIGHT_BUFFER_DEPTH(UB_WB_ROWS)
    ) dut (
        .clk(clk), .rst(rst), .inst_word(inst_type'(inst_word)),
        .inst_write_enable(inst_enable), .inst_fifo_full(full),
        .dma_cmd_addr(dma_cmd_addr), .dma_cmd_len(dma_cmd_len), .dma_cmd_write(dma_cmd_write),
        .dma_cmd_valid(dma_cmd_valid), .dma_cmd_ready(dma_cmd_ready),
        .dma_rsp_data(dma_rsp_data), .dma_rsp_valid(dma_rsp_valid),
        .dma_rsp_ready(dma_rsp_ready),
        .dma_write_data(dma_write_data), .dma_write_strb(dma_write_strb),
        .dma_write_data_valid(dma_write_data_valid), .dma_write_data_ready(dma_write_data_ready),
        .uart_result_data(result_data), .uart_result_bytes(result_bytes),
        .uart_result_valid(result_valid), .uart_result_ready(result_ready),
        .synchronize(synchronized), .memory_error(core_fault)
    );
    qpi_ctrl #(.INGRESS_BYTES(INGRESS_BYTES)) qpi (
        .clk(clk), .rst_n(rst_n),
        .dma_cmd_addr(dma_cmd_addr), .dma_cmd_len(dma_cmd_len), .dma_cmd_write(dma_cmd_write),
        .dma_cmd_valid(dma_cmd_valid), .dma_cmd_ready(dma_cmd_ready),
        .dma_rsp_data(dma_rsp_data), .dma_rsp_valid(dma_rsp_valid),
        .dma_rsp_ready(dma_rsp_ready),
        .dma_write_data(dma_write_data), .dma_write_strb(dma_write_strb),
        .dma_write_data_valid(dma_write_data_valid), .dma_write_data_ready(dma_write_data_ready),
        .input_valid(input_valid), .input_addr(input_addr), .input_data(input_data),
        .input_ready(input_ready), .input_done(input_done),
        .fetch_req(memory_fetch_req), .fetch_take(memory_fetch_take), .fetch_pair(!boot && fetch_pair),
        .fetch_addr(memory_fetch_addr),
        .fetch_words(3'd1), .fetch_valid(fetch_valid), .fetch_data(fetched_word),
        .sck(sck), .cs_n(cs_n), .dq_out(dq_out), .dq_oe(dq_oe), .dq_in(dq_in)
    );
    uart #(.INGRESS_BYTES(INGRESS_BYTES), .SLOT_BITS(3)) uart_io (
        .clk(clk), .rst_n(rst_n), .rx(ready ? rx : 1'b1), .tx(tx), .fault(uart_fault),
        .uart_clks_per_bit(uart_clks_per_bit), .input_bytes(channels), .sync(synchronized),
        .complete_frames(complete_frames),
        .frame_ready(frame_ready), .frame_slot(frame_slot), .available_bytes(available_bytes),
        .input_valid(input_valid), .input_addr(input_addr), .input_data(input_data),
        .input_ready(input_ready), .input_done(input_done),
        .result_valid(result_valid), .result_data(result_data), .result_bytes(result_bytes),
        .result_ready(result_ready)
    );
    program_sequencer #(.VPU_WB_BASE(UB_WB_ROWS)) program_ctrl (
        .complete_frames(complete_frames),
        .batch_size(batch_size),
        .clk(clk), .rst_n(rst_n && ready), .sync(synchronized), .frame_ready(frame_ready),
        .frame_slot(frame_slot), .available_bytes(available_bytes), .full(full),
        .inst_word(inst_word), .inst_enable(inst_enable),
        .fetch_req(fetch_req), .fetch_take(fetch_take), .fetch_pair(fetch_pair), .fetch_addr(fetch_addr),
        .fetched_word(fetched_word), .fetch_valid(fetch_valid)
    );
endmodule
