`timescale 1ns/1ps
module tb_vpu_shared;
    import tpu_pkg::*;
    logic clk=0, rst=1, load_weight=0, input_valid=0, last_sum_valid=0;
    fp16_type [1:0] weights, inputs, sums, result, expected;
    logic result_valid;
    logic [31:0] rng=32'h12345678;
    integer checks=0;
    vpu #(.COMPUTE_WIDTH(2)) dut(clk,rst,weights,load_weight,inputs,input_valid,sums,last_sum_valid,result,result_valid);
    always #5 clk=~clk;
    function automatic logic [31:0] next_random(input logic [31:0] v);
        v=v^(v<<13);v=v^(v>>17);v=v^(v<<5);return v;
    endfunction
    initial begin
        repeat(2) @(negedge clk);rst=0;
        for(int n=0;n<10000;n++) begin
            rng=next_random(rng);weights=rng;
            load_weight=1;
            @(negedge clk);load_weight=0;
            rng=next_random(rng);inputs=rng;
            rng=next_random(rng);sums=rng;
            last_sum_valid=n[0];input_valid=1;
            for(int i=0;i<2;i++) expected[i]=fp16_add(fp16_mul(inputs[i],weights[i]),last_sum_valid ? sums[i] : FP16_ZERO);
            @(negedge clk);input_valid=0;inputs=~inputs;sums=~sums;
            while(!result_valid) @(negedge clk);
            if(result!==expected) $fatal(1,"case %0d got=%h expected=%h",n,result,expected);
            checks+=2;
            @(negedge clk);
            if(result_valid) $fatal(1,"duplicate result");
        end
        // Reset during issue/drain discards all pending lane results.
        for(int delay_cycles=0;delay_cycles<5;delay_cycles++) begin
            input_valid=1;
            @(negedge clk);input_valid=0;
            repeat(delay_cycles) @(negedge clk);
            rst=1;
            @(negedge clk);rst=0;
            repeat(7) begin
                @(negedge clk);
                if(result_valid) $fatal(1,"result escaped reset");
            end
        end
        $display("PASS: %0d shared MAC bit-exact lane checks and reset",checks);
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
