// A separate FP8 MAC processes each element of the architectural vector.
module vpu
    import tpu_pkg::*;
#(parameter int COMPUTE_WIDTH = 2)(
    input logic clk, rst,
    input fp8_type [COMPUTE_WIDTH-1:0] weight_data,
    input logic load_weight,
    input fp8_type [COMPUTE_WIDTH-1:0] input_data,
    input logic input_valid,
    input fp8_type [COMPUTE_WIDTH-1:0] last_sum_data,
    input logic last_sum_valid,
    output fp8_type [COMPUTE_WIDTH-1:0] result,
    output logic result_valid
);
    fp8_type [COMPUTE_WIDTH-1:0] weights;
    logic [2:0] valid_pipe;

    // The MAC registers operands, then the product, then the sum.
    assign result_valid = valid_pipe[2];
    always_ff @(posedge clk) begin
        if (rst) begin
            weights <= '0;
            valid_pipe <= '0;
        end else begin
            if (load_weight) weights <= weight_data;
            valid_pipe <= {valid_pipe[1:0], input_valid};
        end
    end

    for (genvar lane = 0; lane < COMPUTE_WIDTH; ++lane) begin : lanes
        mac_unit mac (
            .clk(clk), .rst(rst),
            .weight_in(load_weight ? weight_data[lane] : weights[lane]),
            .load_weight(input_valid),
            .data_in(input_data[lane]),
            .last_sum(last_sum_valid ? last_sum_data[lane] : FP8_ZERO),
            .partial_sum(result[lane])
        );
    end
endmodule
