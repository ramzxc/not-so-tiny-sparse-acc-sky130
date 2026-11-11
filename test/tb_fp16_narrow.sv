module tb_fp16_narrow;
    logic [15:0] a, b, actual, expected;
    logic [31:0] rng = 32'h51ac79e3;
    integer checks = 0;

    task automatic check(input string operation, input logic [15:0] got, want);
        if (got !== want)
            $fatal(1, "%s a=%h b=%h got=%h expected=%h", operation, a, b, got, want);
        checks++;
    endtask

    initial begin
        // Every binary16 encoding, including NaNs, infinities and subnormals.
        for (int i = 0; i < 65536; i++) begin
            a = 16'(i);
            check("sigmoid", tpu_pkg::fp16_sigmoid(a), fp16_reference_pkg::fp16_sigmoid(a));
            check("tanh", tpu_pkg::fp16_tanh(a), fp16_reference_pkg::fp16_tanh(a));
            check("relu", tpu_pkg::fp16_relu(a), fp16_reference_pkg::fp16_relu(a));
            check("step", tpu_pkg::fp16_heaviside_step(a), fp16_reference_pkg::fp16_heaviside_step(a));
            for (int k = -32; k <= 32; k++)
                check("shift", tpu_pkg::fp16_shift_right(a,k), fp16_reference_pkg::fp16_shift_right(a,k));
            b = a ^ 16'h8000;
            check("cancel", tpu_pkg::fp16_add(a,b), fp16_reference_pkg::fp16_add(a,b));
            b = a;
            check("double", tpu_pkg::fp16_add(a,b), fp16_reference_pkg::fp16_add(a,b));
        end
        for (int i = 0; i < 1000000; i++) begin
            rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
            a = rng[15:0]; b = rng[31:16];
            check("add", tpu_pkg::fp16_add(a,b), fp16_reference_pkg::fp16_add(a,b));
            check("mul", tpu_pkg::fp16_mul(a,b), fp16_reference_pkg::fp16_mul(a,b));
        end
        $display("PASS: %0d bit-exact FP16 comparisons", checks);
        $finish;
    end
endmodule
