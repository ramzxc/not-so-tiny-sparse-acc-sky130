// Activation controller
// What it does?
// 1) Receive instruction from the decoder
// 2) Read data from the accumulation buffer ([acc_addr+length:acc_addr])
// 3) Redirect the accumulation buffer data to the activation unit
// 4) Receive the result from the activation unit
// 5) Redirect the result to the unified buffer
// ([buffer_addr+length:buffer_addr])
module activation_ctrl
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH    = 14,
    parameter int META_FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst,

    // Activate instruction input
    input  activate_inst_type    inst,
    input  logic                 inst_enable,

    // Address-only read request -> accumulator register file
    output accumulator_addr_type acc_req_addr,
    output logic                 acc_req_valid,
    input  logic                 acc_req_ready,

    // Data-only read response <- accumulator register file
    input  fp16_type [COMPUTE_WIDTH-1:0] acc_rsp_data,
    input  logic                         acc_rsp_valid,
    output logic                         acc_rsp_ready,

    // Paired data + metadata (function type) -> activation unit
    output fp16_type [COMPUTE_WIDTH-1:0] activation_data,
    output activation_type               activation_function,
    output logic                         activation_data_valid,
    input  logic                         activation_data_ready,

    // Activation response <- activation unit
    input  fp16_type [COMPUTE_WIDTH-1:0] activation_rsp_data,
    input  logic                         activation_rsp_valid,
    output logic                         activation_rsp_ready,

    // Paired activation result + destination metadata -> unified buffer
    output buffer_addr_type              buffer_write_addr,
    output fp16_type [COMPUTE_WIDTH-1:0] buffer_write_data,
    output logic                         buffer_write_valid,
    input  logic                         buffer_write_ready,

    output logic busy,
    output logic resource_busy
);

    localparam int FIFO_PTR_WIDTH =
        (META_FIFO_DEPTH > 1) ? $clog2(META_FIFO_DEPTH) : 1;

    localparam int FIFO_COUNT_WIDTH =
        $clog2(META_FIFO_DEPTH + 1);

    // FIFO QUEUE-RELATED DATA
    // Why do we need a fifo queue? (For all controllers)
    // We need to temporarily keep (1) the decoded results
    // (2) the generated addresses, and (3) etc @ correct timing
    typedef logic [FIFO_PTR_WIDTH-1:0]      fifo_ptr_type;
    typedef logic [FIFO_COUNT_WIDTH-1:0]    fifo_count_type;

    typedef struct packed {
        activation_type  function_sel;
        buffer_addr_type buffer_addr;
    } activation_meta_type;

    activation_meta_type meta_fifo [META_FIFO_DEPTH-1:0];

    // We have decoded + generated all the addresses for the given
    // instruction!
    logic issue_valid_cs;
    // Decode results
    activation_type             function_cs;

    // The generated local mem addresses
    accumulator_addr_type       acc_addr_cs;
    buffer_addr_type            buffer_addr_cs;

    // The number of remaining requests to generate addresses
    logic [LENGTH_WIDTH-1:0]    requests_left_cs;

    // There are three pointers
    // 1) the tail pointer
    // 2) read pointer for activation unit
    // 3) read pointer for unified buffer (result)
    fifo_ptr_type    write_ptr_cs;
    fifo_ptr_type    activation_ptr_cs;
    fifo_ptr_type    buffer_ptr_cs;

    // Fifo is full -> we are not allowed to push the entry
    logic fifo_full;

    // 4-stage handshake conditions
    // 1) Receive instruction from the instruction decoder
    // Condition
    // - The input instruction is valid
    // - We have finished decoding the instruction
    // 2) Gen Addr -> Acc buffer
    // - The generated address is valid
    // - Accum buffer is ready
    // - There is a remaining entry in the fifo
    // 3) Acc buffer -> Act Unit
    // - Receive valid response from the buffer
    // - Activation unit is ready
    // 4) Write the result to the unified buffer
    // - Receive a valid activation result
    // - The unified buffer is ready
    logic accept_inst;
    logic acc_request_fire;
    logic acc_response_fire;
    logic buffer_write_fire;

    function automatic fifo_ptr_type next_ptr(input fifo_ptr_type ptr);
        if (ptr == fifo_ptr_type'(META_FIFO_DEPTH - 1))
            next_ptr = '0;
        else
            next_ptr = ptr + 1'b1;
    endfunction

    assign fifo_full = (next_ptr(write_ptr_cs) == buffer_ptr_cs);

    assign busy          = issue_valid_cs;
    assign resource_busy = issue_valid_cs || (write_ptr_cs != buffer_ptr_cs);

    assign accept_inst = inst_enable && !issue_valid_cs;

    // Registered FIFO occupancy avoids a ready-to-valid loop through mem_ctrl.
    assign acc_req_valid =
        issue_valid_cs && !fifo_full;

    assign acc_req_addr     = acc_addr_cs;
    assign acc_request_fire = acc_req_valid && acc_req_ready;

    // The register-file response is held until the activation input accepts it.
    assign activation_data       = acc_rsp_data;
    assign activation_data_valid =
        acc_rsp_valid && (write_ptr_cs != activation_ptr_cs);

    assign activation_function = activation_data_valid
        ? meta_fifo[activation_ptr_cs].function_sel
        : no_activation;

    assign acc_rsp_ready =
        activation_data_ready && (write_ptr_cs != activation_ptr_cs);

    assign acc_response_fire = acc_rsp_valid && acc_rsp_ready;

    // The activation unit holds its response until the unified-buffer write
    // port accepts the result. The destination address remains in the FIFO.
    assign buffer_write_data  = activation_rsp_data;
    assign buffer_write_valid =
        activation_rsp_valid && (activation_ptr_cs != buffer_ptr_cs);

    assign buffer_write_addr = buffer_write_valid
        ? meta_fifo[buffer_ptr_cs].buffer_addr
        : '0;

    assign activation_rsp_ready =
        buffer_write_ready && (activation_ptr_cs != buffer_ptr_cs);

    assign buffer_write_fire =
        buffer_write_valid && buffer_write_ready;

`ifndef SYNTHESIS
    initial begin
        if (META_FIFO_DEPTH < 2)
            $fatal(1, "activation_ctrl META_FIFO_DEPTH must be at least two");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            issue_valid_cs          <= 1'b0;
            requests_left_cs        <= '0;
            acc_addr_cs             <= '0;
            buffer_addr_cs          <= '0;
            function_cs             <= no_activation;

            write_ptr_cs            <= '0;
            activation_ptr_cs          <= '0;
            buffer_ptr_cs   <= '0;
        end
        else begin
            // Stage1: Instruction Decode (Further decode)
            if (accept_inst) begin
                issue_valid_cs   <= (inst.length != '0);
                requests_left_cs <= inst.length;
                acc_addr_cs      <= inst.acc_addr;
                buffer_addr_cs   <= inst.buffer_addr;
                function_cs      <= activation_type'(inst.opcode[3:0]);
            end

            // Stage2: Address generation
            // - Send request to the acc buffer
            // - Push metadata to the FIFO
            // - Next address calculation
            if (acc_request_fire) begin
                meta_fifo[write_ptr_cs] <= '{
                    function_sel: function_cs,
                    buffer_addr:  buffer_addr_cs
                };

                write_ptr_cs     <= next_ptr(write_ptr_cs);
                requests_left_cs <= requests_left_cs - 1'b1;
                acc_addr_cs      <= acc_addr_cs + 1'b1;
                buffer_addr_cs   <= buffer_addr_cs + 1'b1;

                if (requests_left_cs == 1)
                    issue_valid_cs   <= 1'b0;
            end

            // Stage3: Receive response from the AB
            // - Pop the entry from the fifo queue
            if (acc_response_fire)
                activation_ptr_cs <= next_ptr(activation_ptr_cs);

            // Stage4: Receive response from the activation unit
            // - Send the result to the UB
            if (buffer_write_fire)
                buffer_ptr_cs <= next_ptr(buffer_ptr_cs);
        end
    end

endmodule
