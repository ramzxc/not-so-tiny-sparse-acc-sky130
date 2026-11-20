`timescale 1ns/1ps
// Pin-level native simulation of a complete FP8 EGRU+FC UART program.
module tb_fp8_consumer;
    parameter integer UART_CLKS_PER_BIT=87;
    // Measurement fixture only: ideal command availability at the existing FIFO.
    // This is not a command storage/controller implementation in the chip.
    parameter bit DIRECT_FEED=1;
    parameter time FLASH_PROGRAM_TIME=3ms;
    logic [15:0] feed_inst=0;
    logic feed_valid=0;
    initial if(DIRECT_FEED) begin
        force dut.rx_inst=feed_inst;
        force dut.rx_inst_val=feed_valid;
    end
    logic clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire [7:0] uo_out,uio_out,uio_oe;
    wire [3:0] dq;
    acc_hard_macro #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx_i(rx),.qspi_dq_i(dq),
        .uo_out(uo_out),.uio_out(uio_out),.uio_oe(uio_oe));
    defparam dut.itf.memory.size_1k.macro.VERBOSE=0;
    qspi_nor_model #(.DEPTH(1048576),.BOARD_PREPARED(1),.PROGRAM_TIME(FLASH_PROGRAM_TIME)) flash_model(
        .clk(clk),.sck(uio_out[3]),.cs_n(uio_out[0]),
        .dq_out({uio_out[5:4],uio_out[2:1]}),.dq_oe({uio_oe[5:4],uio_oe[2:1]}),
        .dq_in(dq),.stuck_busy(1'b0),.reject_wren(1'b0),.ignore_qe(1'b0));
    logic [31:0] commands[0:65535];logic [63:0] expected[0:256];
    integer credits=0,phase=0,words,fd,addr,failures=0,reads_start;
    longint cycles=0,dma_cycles=0,micro_cycles=0,compute_cycles=0;
    longint phase_cycles[10],phase_words[10];
    bit measuring=0;
    string flash_file,command_file,expected_file,report_file;
    logic [7:0] received;
    logic [15:0] actual;
    always @(posedge clk) if(measuring) begin
        cycles++;phase_cycles[phase]++;
        if(dut.dma_busy)dma_cycles++;
        if(dut.micro_busy)micro_cycles++;
    end
    // Exclusive attribution of core cycles; orthogonal engine counters below.
    longint core_profile[10], qspi_profile[10], sram_profile[9];
    longint exec_active_cycles=0;
    always @(posedge clk) if(measuring && compute_cycles==0) begin
        if(dut.dma_busy) begin
            case(dut.dma.state)
                1,2:core_profile[0]++;
                3,4:core_profile[1]++;
                default:core_profile[2]++;
            endcase
        end else if(dut.micro_busy) begin
            case(dut.command.sequencer.state)
                7,8,9,10,11:core_profile[3]++;
                12,13:core_profile[4]++;
                14,15,16,17,18:core_profile[5]++;
                1,2,3,4,5,6,19,30:core_profile[6]++;
                22,23,24,25,26,27,28,29:core_profile[7]++;
                default:core_profile[8]++;
            endcase
        end else core_profile[9]++;
        qspi_profile[dut.psram.serial_memory.state]++;
        sram_profile[dut.itf.state]++;
        if(!dut.exec_rdy)exec_active_cycles++;
    end
    initial if(!DIRECT_FEED) forever begin
        @(negedge uo_out[4]);
        repeat(UART_CLKS_PER_BIT+UART_CLKS_PER_BIT/2) @(posedge clk);
        for(int b=0;b<8;b++) begin
            received[b]=uo_out[4];repeat(UART_CLKS_PER_BIT) @(posedge clk);
        end
        if(received!==8'h01 || uo_out[4]!==1) $fatal(1,"bad READY %h",received);
        credits++;
    end
    task send_byte(input logic [7:0] value);
        @(negedge clk);rx=0;repeat(UART_CLKS_PER_BIT) @(negedge clk);
        for(int b=0;b<8;b++)begin rx=value[b];repeat(UART_CLKS_PER_BIT) @(negedge clk);end
        rx=1;repeat(UART_CLKS_PER_BIT) @(negedge clk);
    endtask
    task retire;
        if(DIRECT_FEED) begin
            @(negedge clk);
            while(dut.fifo.count!=0 || dut.micro_busy || dut.dma_busy || !dut.exec_rdy || !dut.data_rdy)
                @(negedge clk);
        end else begin wait(credits>0);@(negedge clk);end
    endtask
    task send_word(input logic [15:0] value);
        if(DIRECT_FEED) begin
            @(negedge clk);
            while(!dut.fifo_rdy) @(negedge clk);
            feed_inst=value;feed_valid=1;
            @(negedge clk);feed_valid=0;
        end else begin
            wait(credits>0);credits--;
            send_byte(value[7:0]);send_byte(value[15:8]);
        end
    endtask
    initial begin
        #1;
        if(!$value$plusargs("FLASH=%s",flash_file) || !$value$plusargs("COMMANDS=%s",command_file) ||
           !$value$plusargs("EXPECTED=%s",expected_file) || !$value$plusargs("REPORT=%s",report_file) ||
           !$value$plusargs("WORDS=%d",words))$fatal(1,"missing workload arguments");
        $readmemh(flash_file,flash_model.mem);$readmemh(command_file,commands);$readmemh(expected_file,expected);
        repeat(10) @(negedge clk);rst_n=1;repeat(4) @(negedge clk);
        for(int k=0;k<words;k++)begin
            if(commands[k][31:16]==16'hffff)begin
                retire();
                if(commands[k][15:0]==1)begin measuring=1;reads_start=flash_model.read_ops;end
                else if(commands[k][15:0]==3)compute_cycles=cycles;
                else measuring=0;
            end else begin
                phase=int'(commands[k][31:16]);
                if(measuring)phase_words[phase]++;
                send_word(commands[k][15:0]);
            end
        end
        if(uo_out[1])$fatal(1,"DUT sticky error");
        for(int k=0;k<257;k++)begin
            addr=int'(expected[k]>>32);
            actual=16'(dut.itf.memory.size_1k.macro.mem[addr>>3]>>(8*(addr&7)));
            if(actual!==expected[k][15:0])begin
                if(failures<12)$display("mismatch addr=%0d actual=%h expected=%h",addr,actual,expected[k][15:0]);
                failures++;
            end
        end
        if({flash_model.mem[20'hf0001],flash_model.mem[20'hf0000]}!==expected[256][15:0])begin
            $display("Flash output mismatch");failures++;
        end
        fd=$fopen(report_file,"w");
        $fwrite(fd,"{\"direct_feed\":%0d,\"compute_cycles\":%0d,\"flash_export_cycles\":%0d,\"uart_clks_per_bit\":%0d,\"cycles\":%0d,\"dma_cycles\":%0d,\"micro_cycles\":%0d,\"mismatches\":%0d,\"flash_reads\":%0d,\"flash_programs\":%0d,\"phase_cycles\":[",DIRECT_FEED,compute_cycles,cycles-compute_cycles,UART_CLKS_PER_BIT,cycles,dma_cycles,micro_cycles,failures,flash_model.read_ops-reads_start,flash_model.program_ops);
        for(int p=0;p<10;p++)$fwrite(fd,"%s%0d",p?",":"",phase_cycles[p]);
        $fwrite(fd,"],\"phase_words\":[");
        for(int p=0;p<10;p++)$fwrite(fd,"%s%0d",p?",":"",phase_words[p]);
        $fwrite(fd,"],\"core_profile\":[");
        for(int p=0;p<10;p++)$fwrite(fd,"%s%0d",p?",":"",core_profile[p]);
        $fwrite(fd,"],\"qspi_profile\":[");
        for(int p=0;p<10;p++)$fwrite(fd,"%s%0d",p?",":"",qspi_profile[p]);
        $fwrite(fd,"],\"sram_profile\":[");
        for(int p=0;p<9;p++)$fwrite(fd,"%s%0d",p?",":"",sram_profile[p]);
        $fwrite(fd,"],\"exec_active_cycles\":%0d}\n",exec_active_cycles);$fclose(fd);
        if(failures || flash_model.program_ops!=2)$fatal(1,"full network failed: %0d mismatches",failures);
        $display("PASS complete FP8 EGRU+FC: %0d cycles",cycles);$finish;
    end
    initial begin repeat(150000000) @(posedge clk);$fatal(1,"timeout");end
endmodule
