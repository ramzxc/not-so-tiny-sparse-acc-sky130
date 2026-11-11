// Accumulation register file with a two-stage write pipeline and one
// physical read port shared by activation and DRAM-store traffic.
module register_file
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH  = 4,
    parameter int REGISTER_DEPTH = 1 << ACCUMULATOR_ADDR_WIDTH
)(
    input logic clk,
    input logic rst,

    // 1) VPU -> Accum
    // 2) DRAM -> Accum
    input  accumulator_addr_type         write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] data_in,
    input  logic                         write_enable,
    input  logic                         accumulate,

    // 1) Accum -> Activation unit
    // 2) Accum -> DRAM
    input  accumulator_addr_type         read_req_addr,
    input  logic                         read_req_valid,
    output logic                         read_req_ready,
    output fp16_type [COMPUTE_WIDTH-1:0] read_rsp_data,
    output logic                         read_rsp_valid,
    input  logic                         read_rsp_ready
);

    localparam int SRAM_DATA_WIDTH = COMPUTE_WIDTH * FP16_WIDTH;
    localparam int SRAM_ADDR_WIDTH = 8;

    logic [SRAM_DATA_WIDTH-1:0] sram_write_data;
    logic [SRAM_DATA_WIDTH-1:0] sram_read_data;
    fp16_type [COMPUTE_WIDTH-1:0] sram_read_vector;
    logic [SRAM_ADDR_WIDTH-1:0] sram_read_addr;
    logic sram_write_enable;
    logic sram_read_enable;
    logic accumulation_read_enable;

    logic write_forward_from_request;
    logic write_forward_from_result;
    logic read_forward_from_request;
    logic read_forward_from_result;

    // Write pipeline, stage 0.
    fp16_type [COMPUTE_WIDTH-1:0] request_data_cs;
    fp16_type [COMPUTE_WIDTH-1:0] request_old_data_cs;
    accumulator_addr_type         request_addr_cs;
    logic                         request_valid_cs;
    logic                         request_accumulate_cs;
    logic                         request_forward_valid_cs;

    // Write pipeline, stage 1.
    fp16_type [COMPUTE_WIDTH-1:0] result_data_cs;
    fp16_type [COMPUTE_WIDTH-1:0] result_data_ns;
    accumulator_addr_type         result_addr_cs;
    logic                         result_valid_cs;

    logic read_port_available;
    logic read_req_fire;
    logic read_rsp_fire;
    logic read_rsp_stall;
    accumulator_addr_type read_rsp_addr_cs;
    fp16_type [COMPUTE_WIDTH-1:0] read_rsp_forward_data_cs;
    logic                         read_rsp_forward_valid_cs;

    assign sram_write_data = result_data_cs;
    assign sram_read_vector = sram_read_data;
    assign read_rsp_data = read_rsp_forward_valid_cs
        ? read_rsp_forward_data_cs : sram_read_vector;

    assign write_forward_from_request =
        request_valid_cs && (request_addr_cs == write_addr);
    assign write_forward_from_result =
        result_valid_cs && (result_addr_cs == write_addr);
    assign read_forward_from_request =
        request_valid_cs && (request_addr_cs == read_req_addr);
    assign read_forward_from_result =
        result_valid_cs && (result_addr_cs == read_req_addr);

    assign accumulation_read_enable = write_enable && accumulate;

    assign read_port_available =
        !read_rsp_valid || read_rsp_ready;

    assign read_req_ready =
        !accumulation_read_enable && read_port_available;

    assign read_req_fire = read_req_valid && read_req_ready;
    assign read_rsp_fire = read_rsp_valid && read_rsp_ready;
    assign read_rsp_stall = read_rsp_valid && !read_rsp_ready;

    assign sram_write_enable = result_valid_cs;
    assign sram_read_enable =
        (accumulation_read_enable &&
         !write_forward_from_request &&
         !write_forward_from_result) ||
        (read_req_fire &&
         !read_forward_from_request &&
         !read_forward_from_result) ||
        (read_rsp_stall && !read_rsp_forward_valid_cs);
    assign sram_read_addr = accumulation_read_enable
        ? write_addr
        : (read_req_fire ? read_req_addr : read_rsp_addr_cs);

    acc_memory_1r1w_64x256 #(.DATA_WIDTH(SRAM_DATA_WIDTH)) accumulation_sram (
        .clk0  (clk),
        .csb0  (!sram_write_enable),
        .addr0 (result_addr_cs),
        .din0  (sram_write_data),
        .clk1  (clk),
        .csb1  (!sram_read_enable),
        .addr1 (sram_read_addr),
        .dout1 (sram_read_data)
    );

`ifndef SYNTHESIS
    initial begin
        if (COMPUTE_WIDTH < 1)
            $fatal(1, "register_file COMPUTE_WIDTH must be positive");
        if (REGISTER_DEPTH < 1)
            $fatal(1, "register_file REGISTER_DEPTH must be positive");
        if (REGISTER_DEPTH > (1 << ACCUMULATOR_ADDR_WIDTH))
            $fatal(1, "register_file depth exceeds accumulator address space");
        if (SRAM_DATA_WIDTH != 32 && SRAM_DATA_WIDTH != 64)
            $fatal(1, "register_file row width must be 32 or 64 bits");
    end
`endif

    always_comb begin
        for (int i = 0; i < COMPUTE_WIDTH; i++) begin
            // Accumulate or to initialize
            if (request_accumulate_cs)
                result_data_ns[i] =
                    fp16_add(
                        request_data_cs[i],
                        request_forward_valid_cs
                            ? request_old_data_cs[i]
                            : sram_read_vector[i]
                    );
            else
                result_data_ns[i] = request_data_cs[i];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            request_data_cs       <= '0;
            request_old_data_cs   <= '0;
            request_addr_cs       <= '0;
            request_valid_cs      <= 1'b0;
            request_accumulate_cs <= 1'b0;
            request_forward_valid_cs <= 1'b0;

            result_data_cs        <= '0;
            result_addr_cs        <= '0;
            result_valid_cs       <= 1'b0;

            read_rsp_valid        <= 1'b0;
            read_rsp_addr_cs      <= '0;
            read_rsp_forward_data_cs  <= '0;
            read_rsp_forward_valid_cs <= 1'b0;
        end
        else begin
            // VPU -> Accum
            // Pipelined execution of below
            // Stage1: Receive the data (Read accum if needed)
            // Stage2: Compute (Accumulate the value)
            // Stage3: Write the result to the accumulator


            // Prepare data
            request_data_cs       <= data_in;
            request_addr_cs       <= write_addr;
            request_valid_cs      <= write_enable;
            request_accumulate_cs <= accumulate;

            // Stage1
            request_forward_valid_cs <= 1'b0;
            if (write_enable && accumulate) begin
                // Forwarding Unit
                // Option #1: One cycle (The accumulated result ready)
                if (write_forward_from_request) begin
                    request_old_data_cs <= result_data_ns;
                    request_forward_valid_cs <= 1'b1;
                end
                // Option #2: Two cycles (The write not done)
                else if (write_forward_from_result) begin
                    request_old_data_cs <= result_data_cs;
                    request_forward_valid_cs <= 1'b1;
                end
                // No dependency
                else begin
                    request_old_data_cs <= '0;
                end
            end
            else begin
                request_old_data_cs <= '0;
            end

`ifndef SYNTHESIS
            if (write_enable &&
                ($unsigned(write_addr) >= REGISTER_DEPTH)) begin
                $error(
                    "Accumulator request address %0d is outside REGISTER_DEPTH=%0d",
                    $unsigned(write_addr),
                    REGISTER_DEPTH
                );
            end
`endif

            // Stage2
            // Move from the request to result
            result_data_cs  <= result_data_ns;
            result_addr_cs  <= request_addr_cs;
            result_valid_cs <= request_valid_cs;

`ifndef SYNTHESIS
            // Stage3
            // Write back
            if (result_valid_cs &&
                ($unsigned(result_addr_cs) >= REGISTER_DEPTH)) begin
                $error(
                    "Accumulator write address %0d is outside REGISTER_DEPTH=%0d",
                    $unsigned(result_addr_cs),
                    REGISTER_DEPTH
                );
            end
`endif


            // Read the data from the accumulation buffer
            if (read_rsp_fire) begin
                read_rsp_valid <= 1'b0;
                read_rsp_forward_valid_cs <= 1'b0;
            end

            if (read_req_fire) begin
                read_rsp_addr_cs <= read_req_addr;
                read_rsp_forward_valid_cs <= 1'b0;

                if (read_forward_from_request) begin
                    read_rsp_forward_data_cs <= result_data_ns;
                    read_rsp_forward_valid_cs <= 1'b1;
                end
                else if (read_forward_from_result) begin
                    read_rsp_forward_data_cs <= result_data_cs;
                    read_rsp_forward_valid_cs <= 1'b1;
                end
                else begin
                    read_rsp_forward_data_cs <= '0;
                end

`ifndef SYNTHESIS
                if ($unsigned(read_req_addr) >= REGISTER_DEPTH) begin
                    $error(
                        "Accumulator read address %0d is outside REGISTER_DEPTH=%0d",
                        $unsigned(read_req_addr),
                        REGISTER_DEPTH
                    );
                end
`endif

                read_rsp_valid <= 1'b1;
            end
        end
    end

endmodule
