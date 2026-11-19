`include "../defs/defs.vh"
`include "../defs/inst_defs.vh"

// Tiny rebuild EXEC contract, implemented with the existing FP8 arithmetic.
// Two architectural lanes share one multiplier and one arithmetic adder.
// Raw accumulated results precede activation; the output is held until replaced.
module exec_unit (
    input logic clk, rst_n,
    input logic [5:0] exec_inst_in,
    input logic exec_inst_in_val,
    output wire exec_rdy,
    input logic [15:0] data_in,
    input logic data_in_val, is_weight,
    output logic [15:0] data_out,
    output logic data_out_val,
    input logic input_scalar_mode, input_select, input_sparse
);
    `include "defs/fp8_math.vh"
    typedef enum logic [1:0] {IDLE, PRODUCT, ARITHMETIC, ACTIVATE} state_t;
    state_t state;
    logic [15:0] inputs, weights, saved_inputs, saved_weights, accumulator, raw_result;
    logic [5:0] instruction;
    logic lane;
    fp8_type product_reg, add_a, add_b, lane_result;
    wire [7:0] selected_input = inputs[input_select*8 +: 8];
    wire skip_scalar = input_scalar_mode && input_sparse && selected_input[6:0] == 0;
    wire multiply = instruction[4:3] == `VPU_MUL;
    fp8_type activation_input, activation_result;
    assign activation_input = raw_result[lane*8 +: 8];
    assign exec_rdy = rst_n && state == IDLE;
    assign add_a = multiply ? product_reg : saved_inputs[lane*8 +: 8];
    assign add_b = multiply ? accumulator[lane*8 +: 8] :
        {saved_weights[lane*8+7] ^ (instruction[4:3] == `VPU_SUB),
         saved_weights[lane*8 +: 7]};
    assign lane_result = multiply && !instruction[5] ? product_reg : fp8_add(add_a, add_b);
    // One shared hard-activation datapath, with the existing ISA encodings.
    logic signed [6:0] quarter_scale;
    fp8_type quarter, sigmoid_value;
    always_comb begin
        quarter_scale = activation_input[6:3] == 0 ? -7'sd11 :
            $signed({3'b0, activation_input[6:3]}) - 7'sd12;
        quarter = fp8_pack8(activation_input[7],
            {4'b0, (activation_input[6:3] != 0), activation_input[2:0]}, quarter_scale);
        sigmoid_value = fp8_add(quarter, 8'h30);
        case (instruction[2:0])
            `ACT_RELU: activation_result = activation_input[7] ? FP8_ZERO : activation_input;
            `ACT_TANH: activation_result = activation_input[6:0] > 7'h38 ?
                {activation_input[7], 7'h38} : activation_input;
            `ACT_SIGMOID: activation_result = sigmoid_value[7] ? FP8_ZERO :
                sigmoid_value[6:0] > 7'h38 ? 8'h38 : sigmoid_value;
            `ACT_STEP: activation_result = !activation_input[7] && activation_input[6:0] != 0 ?
                8'h38 : FP8_ZERO;
            default: activation_result = activation_input;
        endcase
        if (fp8_is_nan(activation_input[6:0])) activation_result = FP8_QNAN;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            inputs <= 0; weights <= 0; saved_inputs <= 0; saved_weights <= 0;
            accumulator <= 0; raw_result <= 0; instruction <= 0;
            lane <= 0; product_reg <= 0; data_out <= 0; data_out_val <= 0;
        end else begin
            data_out_val <= 0;
            // Updates may overlap execution, but cannot change its snapshot.
            if (data_in_val) begin
                if (is_weight) weights <= data_in;
                else inputs <= data_in;
            end
            case (state)
                IDLE: if (exec_inst_in_val) begin
                    instruction <= exec_inst_in;
                    saved_inputs <= input_scalar_mode ? {2{selected_input}} : inputs;
                    saved_weights <= weights;
                    lane <= 0;
                    if (skip_scalar && exec_inst_in[4:3] == `VPU_MUL) begin
                        // A zero column contributes nothing. Preserve raw partial
                        // sums exactly (including signed zero/NaN payloads).
                        raw_result <= exec_inst_in[5] ? accumulator : 16'b0;
                        if (!exec_inst_in[5]) accumulator <= 0;
                        state <= ACTIVATE;
                    end else state <= PRODUCT;
                end
                PRODUCT: begin
                    product_reg <= fp8_mul(saved_inputs[lane*8 +: 8],
                                            saved_weights[lane*8 +: 8]);
                    state <= ARITHMETIC;
                end
                ARITHMETIC: begin
                    accumulator[lane*8 +: 8] <= lane_result;
                    raw_result[lane*8 +: 8] <= lane_result;
                    if (lane) begin lane <= 0; state <= ACTIVATE; end
                    else begin lane <= 1; state <= PRODUCT; end
                end
                ACTIVATE: begin
                    if (!lane) begin
                        raw_result[7:0] <= activation_result;
                        lane <= 1;
                    end else begin
                        // Publish both lanes together; keep the previous output
                        // stable until the whole instruction has completed.
                        data_out <= {activation_result, raw_result[7:0]};
                        data_out_val <= 1;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
