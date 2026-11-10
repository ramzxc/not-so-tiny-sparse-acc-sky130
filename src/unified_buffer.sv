// Unified FP16 row buffer. The instruction decoder guarantees that at most
// one internal reader and one internal writer are active at a time.
module unified_buffer
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH = 4,
    parameter int DEPTH         = 256
)(
    input logic clk,
    input logic rst,

    // VPU read request/response.
    input  buffer_addr_type              vpu_read_req_addr,
    input  logic                         vpu_read_req_valid,
    output logic                         vpu_read_req_ready,

    output fp16_type [COMPUTE_WIDTH-1:0] vpu_read_rsp_data,
    output logic                         vpu_read_rsp_valid,
    input  logic                         vpu_read_rsp_ready,

    // weight load ctrl read request/response.
    input  buffer_addr_type              weight_read_req_addr,
    input  logic                         weight_read_req_valid,
    output logic                         weight_read_req_ready,

    output fp16_type [COMPUTE_WIDTH-1:0] weight_read_rsp_data,
    output logic                         weight_read_rsp_valid,
    input  logic                         weight_read_rsp_ready,

    // Sparse-Ctrl read request/response (Scalar Only)
    input  buffer_addr_type              sparse_read_req_addr,
    input  logic                         sparse_read_req_valid,
    output logic                         sparse_read_req_ready,

    output fp16_type                     sparse_read_rsp_data, // [수정] 단일 fp16 스칼라
    output logic                         sparse_read_rsp_valid,
    input  logic                         sparse_read_rsp_ready,

    // DMA DRAM-store read request/response.
    input  buffer_addr_type              store_read_req_addr,
    input  logic                         store_read_req_valid,
    output logic                         store_read_req_ready,

    output fp16_type [COMPUTE_WIDTH-1:0] store_read_rsp_data,
    output logic                         store_read_rsp_valid,
    input  logic                         store_read_rsp_ready,

    // Activation-output write request.
    input  buffer_addr_type              activation_write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] activation_write_data,
    input  logic                         activation_write_valid,
    output logic                         activation_write_ready,

    // DMA DRAM-load full-row write request.
    input  buffer_addr_type              load_write_addr,
    input  fp16_type [COMPUTE_WIDTH-1:0] load_write_data,
    input  logic                         load_write_valid,
    output logic                         load_write_ready
);

    localparam int ROW_WIDTH       = COMPUTE_WIDTH * FP16_WIDTH;
    localparam int SRAM_DATA_WIDTH = 64;
    localparam int SRAM_ADDR_WIDTH = 8;
    localparam int SRAM_DEPTH      = 1 << SRAM_ADDR_WIDTH;

    typedef enum logic [1:0] {
        READ_OWNER_VPU,
        READ_OWNER_SPARSE,
        READ_OWNER_STORE,
        READ_OWNER_WEIGHT
    } read_owner_type;

    buffer_addr_type               internal_read_addr;
    logic                          internal_read_valid;
    logic                          internal_read_ready;
    fp16_type [COMPUTE_WIDTH-1:0]  internal_read_rsp_data;
    logic                          internal_read_rsp_valid;
    logic                          internal_read_rsp_ready;

    read_owner_type request_owner;
    read_owner_type response_owner_cs;

    buffer_addr_type               internal_write_addr;
    fp16_type [COMPUTE_WIDTH-1:0]  internal_write_data;
    logic                          internal_write_valid;
    logic                          internal_write_ready;

    logic internal_read_fire;
    logic internal_read_rsp_fire;
    logic internal_read_rsp_stall;
    logic internal_write_fire;
    logic [ROW_WIDTH-1:0] internal_write_bits;

    logic [SRAM_DATA_WIDTH-1:0] sram_read_data;
    logic [SRAM_ADDR_WIDTH-1:0] sram_read_addr;
    logic [SRAM_ADDR_WIDTH-1:0] sram_write_addr;
    logic sram_read_enable;
    logic sram_write_enable;
    logic internal_read_addr_valid;
    logic internal_write_addr_valid;
    logic response_addr_valid_cs;
    buffer_addr_type response_addr_cs;

    assign internal_read_ready =
        !internal_read_rsp_valid || internal_read_rsp_ready;

    always_comb begin
        internal_read_addr    = '0;
        internal_read_valid   = 1'b0;
        request_owner         = READ_OWNER_VPU;

        vpu_read_req_ready    = 1'b0;
        sparse_read_req_ready = 1'b0;
        weight_read_req_ready = 1'b0;
        store_read_req_ready  = 1'b0;

        if (vpu_read_req_valid) begin
            internal_read_addr    = vpu_read_req_addr;
            internal_read_valid   = 1'b1;
            request_owner         = READ_OWNER_VPU;
            vpu_read_req_ready    = internal_read_ready;
        end
        else if (sparse_read_req_valid) begin
            internal_read_addr    = sparse_read_req_addr;
            internal_read_valid   = 1'b1;
            request_owner         = READ_OWNER_SPARSE;
            sparse_read_req_ready = internal_read_ready;
        end
        else if (weight_read_req_valid) begin
            internal_read_addr    = weight_read_req_addr;
            internal_read_valid   = 1'b1;
            request_owner         = READ_OWNER_WEIGHT;
            weight_read_req_ready = internal_read_ready;
        end
        else if (store_read_req_valid) begin
            internal_read_addr    = store_read_req_addr;
            internal_read_valid   = 1'b1;
            request_owner         = READ_OWNER_STORE;
            store_read_req_ready  = internal_read_ready;
        end
    end

    assign internal_read_fire =
        internal_read_valid && internal_read_ready;

    assign internal_read_addr_valid =
        ($unsigned(internal_read_addr) < DEPTH);
    assign sram_read_enable =
        (internal_read_fire && internal_read_addr_valid) ||
        (internal_read_rsp_stall && response_addr_valid_cs);
    assign sram_read_addr = internal_read_fire
        ? internal_read_addr[SRAM_ADDR_WIDTH-1:0]
        : response_addr_cs[SRAM_ADDR_WIDTH-1:0];

    assign internal_read_rsp_data =
        response_addr_valid_cs ? sram_read_data : '0;

    assign vpu_read_rsp_data    = internal_read_rsp_data;
    assign sparse_read_rsp_data = internal_read_rsp_data[0];
    assign weight_read_rsp_data = internal_read_rsp_data;
    assign store_read_rsp_data  = internal_read_rsp_data;

    always_comb begin
        vpu_read_rsp_valid      = 1'b0;
        sparse_read_rsp_valid   = 1'b0;
        weight_read_rsp_valid   = 1'b0;
        store_read_rsp_valid    = 1'b0;
        internal_read_rsp_ready = 1'b0;

        if (internal_read_rsp_valid) begin
            case (response_owner_cs)
                READ_OWNER_VPU: begin
                    vpu_read_rsp_valid      = internal_read_rsp_valid;
                    internal_read_rsp_ready = vpu_read_rsp_ready;
                end
                READ_OWNER_SPARSE: begin
                    sparse_read_rsp_valid   = internal_read_rsp_valid;
                    internal_read_rsp_ready = sparse_read_rsp_ready;
                end
                READ_OWNER_WEIGHT: begin
                    weight_read_rsp_valid   = internal_read_rsp_valid;
                    internal_read_rsp_ready = weight_read_rsp_ready;
                end
                READ_OWNER_STORE: begin
                    store_read_rsp_valid    = internal_read_rsp_valid;
                    internal_read_rsp_ready = store_read_rsp_ready;
                end
                default: ;
            endcase
        end
    end

    assign internal_read_rsp_fire =
        internal_read_rsp_valid && internal_read_rsp_ready;
    assign internal_read_rsp_stall =
        internal_read_rsp_valid && !internal_read_rsp_ready;

    assign internal_write_ready = 1'b1;

    always_comb begin
        internal_write_addr    = '0;
        internal_write_data    = '0;
        internal_write_valid   = 1'b0;

        activation_write_ready = 1'b0;
        load_write_ready       = 1'b0;

        if (activation_write_valid) begin
            internal_write_addr    = activation_write_addr;
            internal_write_data    = activation_write_data;
            internal_write_valid   = 1'b1;
            activation_write_ready = internal_write_ready;
        end
        else if (load_write_valid) begin
            internal_write_addr    = load_write_addr;
            internal_write_data    = load_write_data;
            internal_write_valid   = 1'b1;
            load_write_ready       = internal_write_ready;
        end
    end

    assign internal_write_fire =
        internal_write_valid && internal_write_ready;

    assign internal_write_bits = internal_write_data;
    assign internal_write_addr_valid =
        ($unsigned(internal_write_addr) < DEPTH);
    assign sram_write_enable =
        internal_write_fire && internal_write_addr_valid;
    assign sram_write_addr =
        internal_write_addr[SRAM_ADDR_WIDTH-1:0];

    acc_memory_1r1w_64x256 unified_sram (
        .clk0  (clk),
        .csb0  (!sram_write_enable),
        .addr0 (sram_write_addr),
        .din0  (internal_write_bits),
        .clk1  (clk),
        .csb1  (!sram_read_enable),
        .addr1 (sram_read_addr),
        .dout1 (sram_read_data)
    );

`ifndef SYNTHESIS
    initial begin
        if (COMPUTE_WIDTH < 1)
            $fatal(1, "unified_buffer COMPUTE_WIDTH must be positive");
        if (DEPTH < 1)
            $fatal(1, "unified_buffer DEPTH must be positive");
        if (DEPTH > SRAM_DEPTH)
            $fatal(1, "unified_buffer DEPTH exceeds the 256-word SRAM macro");
        if (DEPTH > (1 << BUFFER_ADDR_WIDTH))
            $fatal(1, "unified_buffer DEPTH exceeds address space");
        if (ROW_WIDTH != SRAM_DATA_WIDTH)
            $fatal(1, "unified_buffer width must match the 64-bit SRAM macro");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            internal_read_rsp_valid <= 1'b0;
            response_owner_cs       <= READ_OWNER_VPU;
            response_addr_valid_cs  <= 1'b0;
            response_addr_cs        <= '0;
        end
        else begin
            if (internal_read_rsp_fire) begin
                internal_read_rsp_valid <= 1'b0;
                response_addr_valid_cs  <= 1'b0;
            end

            if (internal_read_fire) begin
                internal_read_rsp_valid <= 1'b1;
                response_owner_cs       <= request_owner;
                response_addr_valid_cs  <= internal_read_addr_valid;
                response_addr_cs        <= internal_read_addr;

`ifndef SYNTHESIS
                if (!internal_read_addr_valid) begin
                    $error(
                        "Unified-buffer read address %0d outside DEPTH=%0d",
                        $unsigned(internal_read_addr), DEPTH
                    );
                end
`endif
            end

`ifndef SYNTHESIS
            if (internal_write_fire) begin
                if (!internal_write_addr_valid)
                    $error(
                        "Unified-buffer write address %0d outside DEPTH=%0d",
                        $unsigned(internal_write_addr), DEPTH
                    );
            end
`endif
        end
`ifndef SYNTHESIS
        if (!rst) begin
            if (!$onehot0({
                vpu_read_req_valid,
                sparse_read_req_valid,
                weight_read_req_valid,
                store_read_req_valid
            }))
                $error("Multiple unified-buffer readers are active");

            if (!$onehot0({
                activation_write_valid,
                load_write_valid
            }))
                $error("Multiple unified-buffer writers are active");

            if (internal_read_rsp_valid && !response_addr_valid_cs)
                $error("Unified-buffer read response has no retained owner");
        end
`endif
    end

endmodule
