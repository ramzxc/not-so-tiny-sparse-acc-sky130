// 1D Vector Processing / Matrix Multiply Unit (1D VPU)
module vpu
    import tpu_pkg::*;
#(
    parameter int COMPUTE_WIDTH = 14
)(
    input  logic clk,
    input  logic rst,

    input  fp16_type [COMPUTE_WIDTH-1:0] weight_data,
    input  logic                         load_weight,

    input  fp16_type [COMPUTE_WIDTH-1:0] input_data,
    input  logic                         input_valid,

    input  fp16_type [COMPUTE_WIDTH-1:0] last_sum_data,
    input  logic                         last_sum_valid,

    output fp16_type [COMPUTE_WIDTH-1:0] result,
    output logic                         result_valid
);

    localparam int RESULT_VALID_STAGE = 3;

    fp16_type interim_result [COMPUTE_WIDTH-1:0];
    logic [RESULT_VALID_STAGE-1:0] result_valid_pipe_cs;

    genvar col;
    generate
        for (col = 0; col < COMPUTE_WIDTH; col++) begin : gen_col
            mac_unit mac (
                .clk            (clk),
                .rst            (rst),
                .weight_in      (weight_data[col]),
                .load_weight    (load_weight),
                .data_in        (input_data[col]),
                .last_sum       (last_sum_valid ? last_sum_data[col] : FP16_ZERO),
                .partial_sum    (interim_result[col])
            );
        end
    endgenerate

    always_comb begin
        for (int i = 0; i < COMPUTE_WIDTH; i++) begin
            result[i] = interim_result[i];
        end
    end

    assign result_valid = result_valid_pipe_cs[RESULT_VALID_STAGE-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            result_valid_pipe_cs <= '0;
        end
        else begin
            result_valid_pipe_cs[0] <= input_valid;
            for (int i = 1; i < RESULT_VALID_STAGE; i++) begin
                result_valid_pipe_cs[i] <= result_valid_pipe_cs[i-1];
            end
        end
    end

endmodule
