`timescale 1ns/1ps
module tb_inst_fifo_small;
    import tpu_pkg::*;
    logic clk=0,rst=1,write_en=0,core_busy=1,pop,empty,full;
    inst_type word,data_out;
    logic [63:0] expected[5000];
    logic [31:0] rng=32'hf1f01234;
    integer wr=0,rd=0,simultaneous=0,blocked=0;
    bit do_pop,do_push;
    inst_fifo #(.FIFO_DEPTH(2)) dut(clk,rst,word,write_en,core_busy,data_out,pop,empty,full);
    always #5 clk=~clk;
    initial begin
        word='0;repeat(2) @(negedge clk);rst=0;
        for(int n=0;n<5000;n++) begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            write_en=rng[0];core_busy=rng[1];word=inst_type'({rng,~rng});
            #1;
            if(empty!==(wr==rd) || full!==(wr-rd==1)) $fatal(1,"incorrect occupancy flags");
            if(!empty && data_out!==expected[rd]) $fatal(1,"FIFO data/order");
            do_pop=!core_busy && wr!=rd;
            do_push=write_en && (wr==rd || do_pop);
            if(pop!==do_pop) $fatal(1,"incorrect pop");
            if(do_pop) rd++;
            if(do_push) begin expected[wr]=word;wr++;end
            if(do_pop && do_push) simultaneous++;
            if(write_en && !do_push) blocked++;
            @(negedge clk);
        end
        core_busy=0;write_en=0;
        repeat(2) @(negedge clk);
        if(!empty || simultaneous==0 || blocked==0) $fatal(1,"drain/coverage");
        core_busy=1;write_en=1;
        @(negedge clk);write_en=0;
        if(!full) $fatal(1,"not full before reset");
        rst=1;@(negedge clk);rst=0;
        if(!empty || full || pop) $fatal(1,"reset did not flush FIFO");
        $display("PASS: 5000 two-entry instruction FIFO cycles, full replacement, stalls and reset");
        $finish;
    end
endmodule
