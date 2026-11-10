// Weight SRAM model with one read port and one DMA load-write port.
module weight_buffer
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH = 4,
    parameter int DEPTH         = 256
)(
    input logic clk,
    input logic rst,

    input  weight_addr_type             read_req_addr,
    input  logic                        read_req_valid,
    output logic                        read_req_ready,
    output fp16_type [COMPUTE_WIDTH-1:0] read_rsp_data,
    output logic                        read_rsp_valid,

    // DMA full-row write port.
    input  weight_addr_type             load_write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] load_write_data,
    input  logic                        load_write_valid,
    output logic                        load_write_ready
);

    localparam int SRAM_DATA_WIDTH = 64;
    localparam int SRAM_ADDR_WIDTH = 8;
    localparam int SRAM_DEPTH      = 1 << SRAM_ADDR_WIDTH;

    logic [SRAM_DATA_WIDTH-1:0] sram_write_data;
    logic [SRAM_DATA_WIDTH-1:0] sram_read_data;
    logic [SRAM_ADDR_WIDTH-1:0] sram_write_addr;
    logic [SRAM_ADDR_WIDTH-1:0] sram_read_addr;
    logic sram_write_enable;
    logic sram_read_enable;
    logic read_addr_valid_cs;

    logic read_request_fire;
    logic load_write_fire;

    assign read_req_ready    = 1'b1;
    assign read_request_fire = read_req_valid && read_req_ready;

    assign load_write_ready = 1'b1;
    assign load_write_fire  = load_write_valid && load_write_ready;

    assign sram_write_data = load_write_data;
    assign sram_write_addr = load_write_addr[SRAM_ADDR_WIDTH-1:0];
    assign sram_read_addr  = read_req_addr[SRAM_ADDR_WIDTH-1:0];

    assign sram_write_enable =
        load_write_fire && ($unsigned(load_write_addr) < DEPTH);
    assign sram_read_enable =
        read_request_fire && ($unsigned(read_req_addr) < DEPTH);

    assign read_rsp_data = read_addr_valid_cs ? sram_read_data : '0;

    acc_memory_1r1w_64x256 weight_sram (
        .clk0  (clk),
        .csb0  (!sram_write_enable),
        .addr0 (sram_write_addr),
        .din0  (sram_write_data),
        .clk1  (clk),
        .csb1  (!sram_read_enable),
        .addr1 (sram_read_addr),
        .dout1 (sram_read_data)
    );

`ifndef SYNTHESIS
    initial begin
        if (COMPUTE_WIDTH < 1)
            $fatal(1, "weight_buffer COMPUTE_WIDTH must be positive");
        if (DEPTH < 1)
            $fatal(1, "weight_buffer DEPTH must be positive");
        if (DEPTH > SRAM_DEPTH)
            $fatal(1, "weight_buffer DEPTH exceeds the 256-word SRAM macro");
        if (DEPTH > (1 << WEIGHT_ADDR_WIDTH))
            $fatal(1, "weight_buffer DEPTH exceeds weight address space");
        if ((COMPUTE_WIDTH * FP16_WIDTH) != SRAM_DATA_WIDTH)
            $fatal(1, "weight_buffer width must match the 64-bit SRAM macro");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            read_rsp_valid     <= 1'b0;
            read_addr_valid_cs <= 1'b0;
        end
        else begin
            read_rsp_valid <= read_request_fire;
            read_addr_valid_cs <=
                read_request_fire &&
                ($unsigned(read_req_addr) < DEPTH);

`ifndef SYNTHESIS
            if (read_request_fire) begin
                if ($unsigned(read_req_addr) >= DEPTH) begin
                    $error(
                        "Weight-buffer read address %0d is outside DEPTH=%0d",
                        $unsigned(read_req_addr),
                        DEPTH
                    );
                end
            end

            if (load_write_fire) begin
                if ($unsigned(load_write_addr) >= DEPTH)
                    $error(
                        "Weight-buffer DRAM-load address %0d is outside DEPTH=%0d",
                        $unsigned(load_write_addr),
                        DEPTH
                    );
            end
`endif
        end
    end

endmodule
