module mac_unit
    import tpu_pkg::*;
(
    input  logic     clk,
    input  logic     rst,

    input  fp16_type weight_in,
    input  logic     load_weight,

    input  fp16_type data_in,
    input  fp16_type last_sum,

    output fp16_type partial_sum
);

    fp16_type weight_cs;
    fp16_type data_in_cs;
    fp16_type product_cs;
    fp16_type partial_sum_cs;

    // last_sum을 곱셈기 완료 시점까지 맞춰주는 2단 딜레이 레지스터
    fp16_type last_sum_d1;
    fp16_type last_sum_d2;

    assign partial_sum = partial_sum_cs;

    always_ff @(posedge clk) begin
        if (rst) begin
            weight_cs      <= FP16_ZERO;
            data_in_cs     <= FP16_ZERO;
            product_cs     <= FP16_ZERO;
            partial_sum_cs <= FP16_ZERO;
            last_sum_d1    <= FP16_ZERO;
            last_sum_d2    <= FP16_ZERO;
        end
        else begin
            if (load_weight)
                weight_cs <= weight_in;

            data_in_cs     <= data_in;
            last_sum_d1    <= last_sum;

            product_cs     <= fp16_mul(data_in_cs, weight_cs);
            last_sum_d2    <= last_sum_d1;

            partial_sum_cs <= fp16_add(product_cs, last_sum_d2);
        end
    end

endmodule
