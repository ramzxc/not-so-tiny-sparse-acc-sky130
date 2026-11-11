`timescale 1ns/1ps
module tb_activation_shared;
    import tpu_pkg::*;
    logic clk=0, rst=1, valid=0, ready, out_valid, out_ready=1;
    activation_type fn;
    fp16_type [1:0] din, dout;
    activation #(.COMPUTE_WIDTH(2)) dut(clk,rst,din,valid,ready,fn,dout,out_valid,out_ready);
    always #5 clk=~clk;
    function automatic fp16_type reference(input fp16_type x,input activation_type f);
        case(f)
            sigmoid: reference=fp16_sigmoid(x);
            tanh: reference=fp16_tanh(x);
            relu: reference=fp16_relu(x);
            heaviside_step: reference=fp16_heaviside_step(x);
            default: reference=x;
        endcase
    endfunction
    integer checks=0;
    activation_type tested_functions [5] = '{no_activation,relu,sigmoid,tanh,heaviside_step};
    task automatic transact(input fp16_type a,b,input activation_type f,input bit stall);
        fp16_type [1:0] expected, held;
        expected[0]=reference(a,f);expected[1]=reference(b,f);
        @(negedge clk);
        while (!ready) @(negedge clk);
        din[0]=a;din[1]=b;fn=f;valid=1;
        out_ready=0;
        @(negedge clk);valid=0;
        while (!out_valid) @(negedge clk);
        if (dout !== expected) $fatal(1,"fn=%0d in=%h,%h got=%h expected=%h",f,a,b,dout,expected);
        held=dout;
        if(stall) repeat(3) begin
            din=~din;fn=no_activation;
            @(negedge clk);
            if(!out_valid || dout!==held || ready) $fatal(1,"stalled output changed");
        end
        out_ready=1;
        @(negedge clk);
        checks+=2;
    endtask
    initial begin
        repeat(2) @(negedge clk);rst=0;
        for(int f=0;f<5;f++) begin
            for(int i=0;i<65536;i+=2)
                transact(16'(i),16'(65535-i),tested_functions[f],(i%1024)==0);
        end
        // Reset must discard a request in flight and any pending response.
        @(negedge clk);fn=tanh;din='0;valid=1;
        @(negedge clk);valid=0;
        @(negedge clk);rst=1;
        @(negedge clk);rst=0;
        if(out_valid || !ready) $fatal(1,"reset did not flush activation");
        transact(16'h3c00,16'hbc00,sigmoid,1);
        $display("PASS: %0d activation bit-exact checks, stalls and reset",checks);
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
