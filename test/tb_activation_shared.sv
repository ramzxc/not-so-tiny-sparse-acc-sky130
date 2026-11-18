`timescale 1ns/1ps
// Test every activation input through real EXEC MUL-by-one instructions.
module tb_activation_shared;
    logic clk=0, rst_n=0, valid=0, ready, out_valid;
    logic [5:0] inst;
    logic [31:0] din, dout;
    logic operand_valid=0, weight=0;
    exec_unit dut (
        .clk(clk), .rst_n(rst_n), .exec_inst_in(inst), .exec_inst_in_val(valid),
        .exec_rdy(ready), .data_in(din), .data_in_val(operand_valid), .is_weight(weight),
        .data_out(dout), .data_out_val(out_valid),
        .input_scalar_mode(1'b0), .input_select(1'b0), .input_sparse(1'b0)
    );
    always #5 clk=~clk;
    reg [15:0] golden [0:327679];
    string reference_file;
    initial begin
        if (!$value$plusargs("REFERENCE=%s",reference_file)) $fatal(1,"Missing independent reference vectors");
        $readmemh(reference_file,golden);
    end
    // Oracle order: NONE, RELU, SIGMOID, TANH, STEP. ISA swaps SIGMOID/TANH.
    function automatic logic [2:0] isa_activation(input integer op);
        case(op)
            2: isa_activation=3;
            3: isa_activation=2;
            default: isa_activation=3'(op);
        endcase
    endfunction
    integer checks=0;
    task automatic load_ones;
        @(negedge clk);weight=1;din=32'h3c003c00;operand_valid=1;
        @(negedge clk);operand_valid=0;weight=0;
    endtask
    task automatic transact(input logic [15:0] a,b,input integer op,input bit hold_check);
        logic [31:0] expected, held;
        expected={golden[op*65536+int'(b)],golden[op*65536+int'(a)]};
        @(negedge clk);
        while (!ready) @(negedge clk);
        din={b,a};operand_valid=1;
        @(negedge clk);operand_valid=0;
        inst={1'b0,2'b10,isa_activation(op)};valid=1;held=dout;
        @(negedge clk);valid=0;
        while (!out_valid) begin
            if (dout!==held || ready) $fatal(1,"partial output published during EXEC");
            @(negedge clk);
        end
        if (dout !== expected) $fatal(1,"op=%0d in=%h,%h got=%h expected=%h",op,a,b,dout,expected);
        if (!ready) $fatal(1,"completed EXEC not ready");
        if(hold_check) repeat(3) begin
            din=~din;inst=0;
            @(negedge clk);
            if(out_valid || dout!==expected || !ready) $fatal(1,"held output changed");
        end
        checks+=2;
    endtask
    initial begin
        inst=0;din=0;
        repeat(2) @(negedge clk);rst_n=1;
        load_ones();
        for(int op=0;op<5;op++) begin
            for(int i=0;i<65536;i+=2)
                transact(16'(i),16'(65535-i),op,(i%1024)==0);
        end
        // Cancel in the activation phase, then prove recovery.
        @(negedge clk);inst={1'b0,2'b10,3'd3};valid=1;
        @(negedge clk);valid=0;
        repeat(4) @(negedge clk);
        rst_n=0;
        @(negedge clk);rst_n=1;#1;
        if(out_valid || !ready) $fatal(1,"reset did not flush EXEC");
        load_ones();transact(16'h3c00,16'hbc00,2,1);
        $display("PASS: %0d integrated activation bit-exact checks, held outputs and reset",checks);
        $finish;
    end
    initial begin #100000000; $fatal(1,"timeout"); end
endmodule
