// Two-lane architectural vectors share one pipelined physical MAC.
module vpu
    import tpu_pkg::*;
#(parameter int COMPUTE_WIDTH = 14)(
    input logic clk, rst,
    input fp16_type [COMPUTE_WIDTH-1:0] weight_data,
    input logic load_weight,
    input fp16_type [COMPUTE_WIDTH-1:0] input_data,
    input logic input_valid,
    input fp16_type [COMPUTE_WIDTH-1:0] last_sum_data,
    input logic last_sum_valid,
    output fp16_type [COMPUTE_WIDTH-1:0] result,
    output logic result_valid
);
    localparam int INDEX_WIDTH = COMPUTE_WIDTH > 1 ? $clog2(COMPUTE_WIDTH) : 1;
    typedef enum logic [1:0] {IDLE, ISSUE, DRAIN} state_t;
    state_t state;
    fp16_type [COMPUTE_WIDTH-1:0] weights, inputs, sums;
    logic [INDEX_WIDTH-1:0] issue_index, result_index;
    logic [2:0] valid_pipe;
    fp16_type mac_result;
    logic issue;
    assign issue = state == ISSUE;

    // The MAC captures data and weight on the issue edge. Multiplication
    // uses both captured values on the next edge, then addition follows.
    mac_unit mac (
        .clk(clk), .rst(rst),
        .weight_in(weights[issue_index]), .load_weight(issue),
        .data_in(inputs[issue_index]), .last_sum(sums[issue_index]),
        .partial_sum(mac_result)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            weights <= '0;
            inputs <= '0;
            sums <= '0;
            result <= '0;
            result_valid <= 0;
            issue_index <= '0;
            result_index <= '0;
            valid_pipe <= '0;
        end else begin
            result_valid <= 0;
            valid_pipe <= {valid_pipe[1:0], issue};
            if (load_weight) weights <= weight_data;
            case (state)
                IDLE: if (input_valid) begin
                    inputs <= input_data;
                    sums <= last_sum_valid ? last_sum_data : '0;
                    issue_index <= '0;
                    result_index <= '0;
                    state <= ISSUE;
                end
                ISSUE: begin
                    if (issue_index == INDEX_WIDTH'(COMPUTE_WIDTH-1)) state <= DRAIN;
                    else issue_index <= issue_index + 1'b1;
                end
                default: ;
            endcase
            if (valid_pipe[2]) begin
                result[result_index] <= mac_result;
                if (result_index == INDEX_WIDTH'(COMPUTE_WIDTH-1)) begin
                    result_valid <= 1;
                    state <= IDLE;
                end else result_index <= result_index + 1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (!rst) begin
        if (input_valid && state != IDLE)
            $fatal(1, "VPU controller issued a vector while the shared MAC was busy");
        if (load_weight && state != IDLE)
            $fatal(1, "VPU weights changed while the shared MAC was busy");
    end
`endif
endmodule
