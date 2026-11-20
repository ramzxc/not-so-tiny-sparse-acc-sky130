`timescale 1ns/1ps
// Real 50 MHz / divider-87 UART. Producer sends fixed frames every 20 ms,
// regardless of core progress. Repeated warm-start fixtures isolate transport.
module tb_no_pc_network;
    localparam integer UART_CLKS_PER_BIT=87, FRAMES=8;
    tb_psram_stream #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) bench();
    defparam bench.psram_model.MAX_CS_LOW=3000ns;
    always #10 bench.clk=~bench.clk;
    integer credits=0,words,input_bytes,program_base,fd,failures=0,addr;
    integer peak_queue=0,checked=0;
    integer ingress_blocked_cycles=0,ingress_core_contention_cycles=0;
    logic [7:0] received;
    logic [63:0] expected[0:256];
    logic [15:0] actual;
    longint cycles=0,epoch=0,last_finish=0;
    longint finish_cycles[0:FRAMES-1];
    bit streaming=0;
    string expected_file,report_file;
    always @(posedge bench.clk)begin
        cycles++;
        if(streaming)begin
            if(bench.uo_out[1])$fatal(1,"DUT error during raw streaming");
            if(bench.dut.queue_valid && !bench.dut.queue_ready)begin
                ingress_blocked_cycles++;
                if(bench.dut.psram.ingress_owner.busy && bench.dut.psram.ingress_owner.owner_fetch)
                    ingress_core_contention_cycles++;
            end
            if(bench.queue_count>peak_queue)peak_queue=int'(bench.queue_count);
        end
    end
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
    always @(negedge bench.clk)if(streaming && bench.completed>checked)begin
        if(bench.completed!=checked+1)$fatal(1,"missed completion");
        for(int k=0;k<257;k++)begin
            addr=int'(expected[k]>>32);
            actual=16'(bench.dut.itf.memory.size_1k.macro.mem[addr>>3]>>(8*(addr&7)));
            if(actual!==expected[k][15:0])failures++;
        end
        if({bench.psram_model.mem[20'hf0001],bench.psram_model.mem[20'hf0000]}!==expected[256][15:0])failures++;
        finish_cycles[checked]=cycles-epoch;last_finish=cycles;checked++;
    end
    initial begin
        bench.clk=0;bench.rst_n=0;bench.ena=1;bench.ui_in=8;bench.observe_addr=0;
        if(!$value$plusargs("EXPECTED=%s",expected_file) || !$value$plusargs("REPORT=%s",report_file) ||
           !$value$plusargs("WORDS=%d",words) || !$value$plusargs("PROGRAM=%d",program_base) ||
           !$value$plusargs("INPUT_BYTES=%d",input_bytes))$fatal(1,"missing case");
        $readmemh(expected_file,expected);
        repeat(10)@(negedge bench.clk);bench.rst_n=1;
        word(16'hf100);word(16'(program_base));word(16'(program_base>>16));word(16'(words));word(768);word(16'(input_bytes));
        word(16'hf400);repeat(10)@(negedge bench.clk);
        if(!bench.uo_out[2])$fatal(1,"stream not enabled");
        epoch=cycles;streaming=1;
        for(int frame=0;frame<FRAMES;frame++)begin
            wait(cycles>=epoch+frame*1000000);
            for(int i=0;i<input_bytes;i++)send_byte(bench.psram_model.mem[4096+i]);
            if(input_bytes%2)send_byte(0);
        end
        wait(checked==FRAMES);@(negedge bench.clk);
        if(bench.queue_count!=0 || bench.queue_pending)$fatal(1,"queue not drained");
        // Check every physically stored frame, including padding and slot stride.
        for(int frame=0;frame<FRAMES;frame++)
            for(int i=0;i<input_bytes;i++)
                if(bench.psram_model.mem['h400000+frame*256+i]!==bench.psram_model.mem[4096+i])failures++;
        fd=$fopen(report_file,"w");
        $fwrite(fd,"{\"frames\":%0d,\"mismatches\":%0d,\"peak_queue\":%0d,\"finish_cycles\":[",FRAMES,failures,peak_queue);
        for(int i=0;i<FRAMES;i++)$fwrite(fd,"%s%0d",i==0?"":",",finish_cycles[i]);
        $fwrite(fd,"],\"max_cs_low_ns\":%0d,\"ingress_wait_max_cycles\":%0d,\"ingress_blocked_cycles\":%0d,\"ingress_core_contention_cycles\":%0d}\n",bench.psram_model.max_active,bench.ingress_wait_max,ingress_blocked_cycles,ingress_core_contention_cycles);$fclose(fd);
        if(failures)$fatal(1,"network/queue mismatches %0d",failures);
        $display("PASS %0d raw frames at 20ms; peak queue %0d",FRAMES,peak_queue);$finish;
    end
    initial begin repeat(100000000)@(posedge bench.clk);$fatal(1,"timeout");end
endmodule
