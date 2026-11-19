`timescale 1ns/1ps
module tb_psram_network;
    parameter integer UART_CLKS_PER_BIT=87;
    tb_psram_stream #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) bench();
    defparam bench.psram_model.MAX_CS_LOW=3000ns;
    always #10 bench.clk=~bench.clk;
    integer credits=0,words,input_bytes,program_base,fd,failures=0,addr;
    logic [7:0] received;
    logic [63:0] expected[0:256];
    logic [15:0] actual;
    longint cycles=0,core_cycles=0;
    bit measuring=0;
    string expected_file,report_file;
    always @(posedge bench.clk)if(measuring)begin
        cycles++;
        if(bench.dut.frontend.state>=6)core_cycles++;
    end
    `include "test/psram_profile.svh"
    initial forever begin
        @(negedge bench.uo_out[4]);
        repeat(UART_CLKS_PER_BIT+UART_CLKS_PER_BIT/2)@(posedge bench.clk);
        for(int b=0;b<8;b++)begin received[b]=bench.uo_out[4];repeat(UART_CLKS_PER_BIT)@(posedge bench.clk);end
        if(received!==1 || bench.uo_out[4]!==1)$fatal(1,"invalid credit");
        credits++;
    end
    task send_byte(input logic [7:0] value);
        @(negedge bench.clk);bench.ui_in[3]=0;repeat(UART_CLKS_PER_BIT)@(negedge bench.clk);
        for(int b=0;b<8;b++)begin bench.ui_in[3]=value[b];repeat(UART_CLKS_PER_BIT)@(negedge bench.clk);end
        bench.ui_in[3]=1;repeat(UART_CLKS_PER_BIT)@(negedge bench.clk);
    endtask
    task word(input logic [15:0] value);
        wait(credits>0);credits--;send_byte(value[7:0]);send_byte(value[15:8]);
    endtask
    initial begin
        bench.clk=0;bench.rst_n=0;bench.ena=1;bench.ui_in=8;bench.observe_addr=0;
        if(!$value$plusargs("EXPECTED=%s",expected_file) || !$value$plusargs("REPORT=%s",report_file) ||
           !$value$plusargs("WORDS=%d",words) || !$value$plusargs("PROGRAM=%d",program_base) ||
           !$value$plusargs("INPUT_BYTES=%d",input_bytes))$fatal(1,"missing case");
        $readmemh(expected_file,expected);
        repeat(10)@(negedge bench.clk);bench.rst_n=1;
        word(16'hf100);word(16'(program_base));word(16'(program_base>>16));word(16'(words));word(768);word(16'(input_bytes));
        wait(credits>0);@(negedge bench.clk);measuring=1;
        word(16'hf200);
        for(int i=0;i<input_bytes;i+=2)word({i+1<input_bytes ? bench.psram_model.mem[4096+i+1] : 8'b0,bench.psram_model.mem[4096+i]});
        wait(credits>0);@(negedge bench.clk);measuring=0;
        if(bench.uo_out[1])$fatal(1,"DUT error");
        for(int k=0;k<257;k++)begin
            addr=int'(expected[k]>>32);
            actual=16'(bench.dut.itf.memory.size_1k.macro.mem[addr>>3]>>(8*(addr&7)));
            if(actual!==expected[k][15:0])begin
                if(failures<8)$display("addr %0d actual %h expected %h",addr,actual,expected[k][15:0]);
                failures++;
            end
        end
        if({bench.psram_model.mem[20'hf0001],bench.psram_model.mem[20'hf0000]}!==expected[256][15:0])failures++;
        if(bench.fetches!=(words+3)/4)$fatal(1,"fetch word count");
        fd=$fopen(report_file,"w");
        $fwrite(fd,"{\"cycles\":%0d,\"core_cycles\":%0d,\"mismatches\":%0d,\"fetches\":%0d,\"data_wait_fetch\":%0d,\"fetch_wait_data\":%0d,\"max_cs_low_ns\":%0d}\n",cycles,core_cycles,failures,bench.fetches,bench.data_wait_fetch,bench.fetch_wait_data,bench.psram_model.max_active);
        $fclose(fd);
        if(profile_enabled)dump_profile();
        if(failures)$fatal(1,"FP8 full network mismatches %0d",failures);
        $display("PASS UART input / PSRAM program+weights+output: %0d cycles",cycles);$finish;
    end
    initial begin repeat(20000000)@(posedge bench.clk);$fatal(1,"timeout");end
endmodule
