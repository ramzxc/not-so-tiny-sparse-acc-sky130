// Reuse the reference rebuild's FP8 hard activation, one lane per cycle.
module activation
    import tpu_pkg::*;
#(parameter int COMPUTE_WIDTH=2)(
    input logic clk, rst,
    input fp8_type [COMPUTE_WIDTH-1:0] data_in,
    input logic data_in_valid,
    output logic data_in_ready,
    input activation_type activation_function,
    output fp8_type [COMPUTE_WIDTH-1:0] data_out,
    output logic data_out_valid,
    input logic data_out_ready
);
    localparam int LANE_AW=COMPUTE_WIDTH>1 ? $clog2(COMPUTE_WIDTH) : 1;
    logic busy;
    logic [LANE_AW-1:0] lane;
    fp8_type [COMPUTE_WIDTH-1:0] captured;
    fp8_type x, activated, quarter, sig;
    logic signed [6:0] quarter_scale;
    activation_type mode;
    assign data_in_ready=!busy && (!data_out_valid || data_out_ready);
    assign x=captured[lane];
    always_comb begin
        quarter_scale = x[6:3]==0 ? -7'sd11 : $signed({3'b0,x[6:3]})-7'sd12;
        quarter=fp8_pack8(x[7],{4'b0,(x[6:3]!=0),x[2:0]},quarter_scale);
        sig=fp8_add(quarter,8'h30);
        case(mode)
            relu: activated=x[7] ? FP8_ZERO : x;
            tanh: activated=x[6:0]>7'h38 ? {x[7],7'h38} : x;
            sigmoid: activated=sig[7] ? FP8_ZERO : sig[6:0]>7'h38 ? FP8_ONE : sig;
            heaviside_step: activated=!x[7] && x[6:0]!=0 ? FP8_ONE : FP8_ZERO;
            default: activated=x;
        endcase
        if(fp8_is_nan(x[6:0]))activated=FP8_QNAN;
    end
    always_ff @(posedge clk) begin
        if(rst)begin
            busy<=0; lane<=0; captured<=0; mode<=no_activation;
            data_out<=0; data_out_valid<=0;
        end else begin
            if(data_out_valid && data_out_ready)data_out_valid<=0;
            if(data_in_valid && data_in_ready)begin
                captured<=data_in; mode<=activation_function; lane<=0; busy<=1;
            end
            if(busy)begin
                data_out[lane]<=activated;
                if(lane==LANE_AW'(COMPUTE_WIDTH-1))begin
                    busy<=0; data_out_valid<=1;
                end else lane<=lane+1'b1;
            end
        end
    end
endmodule
