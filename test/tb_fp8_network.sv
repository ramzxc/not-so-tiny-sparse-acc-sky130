`timescale 1ns/1ps
// Pin-level native simulation of a complete FP8 EGRU+FC UART program.
module tb_fp8_network;
    parameter integer UART_CLKS_PER_BIT=87;
    logic clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire [7:0] uo_out,uio_out,uio_oe;
    wire [3:0] dq;
    acc_hard_macro #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx_i(rx),.qspi_dq_i(dq),
        .uo_out(uo_out),.uio_out(uio_out),.uio_oe(uio_oe));
    defparam dut.itf.memory.size_1k.macro.VERBOSE=0;
    qspi_nor_model #(.DEPTH(1048576),.BOARD_PREPARED(1)) flash_model(
        .clk(clk),.sck(uio_out[3]),.cs_n(uio_out[0]),
        .dq_out({uio_out[5:4],uio_out[2:1]}),.dq_oe({uio_oe[5:4],uio_oe[2:1]}),
        .dq_in(dq),.stuck_busy(1'b0),.reject_wren(1'b0),.ignore_qe(1'b0));
    logic [31:0] commands[0:65535];logic [63:0] expected[0:256];
    integer credits=0,phase=0,words,fd,addr,failures=0,reads_start;
    longint cycles=0,dma_cycles=0,micro_cycles=0;
    longint phase_cycles[9],phase_words[9];
    bit measuring=0;
    string flash_file,command_file,expected_file,report_file;
    logic [7:0] received;
    logic [15:0] actual;
    always @(posedge clk) if(measuring) begin
        cycles++;phase_cycles[phase]++;
        if(dut.dma_busy)dma_cycles++;
        if(dut.micro_busy)micro_cycles++;
    end
    initial forever begin
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
    initial begin
        #1;
        if(!$value$plusargs("FLASH=%s",flash_file) || !$value$plusargs("COMMANDS=%s",command_file) ||
           !$value$plusargs("EXPECTED=%s",expected_file) || !$value$plusargs("REPORT=%s",report_file) ||
           !$value$plusargs("WORDS=%d",words))$fatal(1,"missing workload arguments");
        $readmemh(flash_file,flash_model.mem);$readmemh(command_file,commands);$readmemh(expected_file,expected);
        repeat(10) @(negedge clk);rst_n=1;
        for(int k=0;k<words;k++)begin
            if(commands[k][31:16]==16'hffff)begin
                wait(credits>0);@(negedge clk);
                if(commands[k][15:0]==1)begin measuring=1;reads_start=flash_model.read_ops;end
                else measuring=0;
            end else begin
                phase=int'(commands[k][31:16]);
                wait(credits>0);credits--;
                if(measuring)phase_words[phase]++;
                send_byte(commands[k][7:0]);send_byte(commands[k][15:8]);
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
        fd=$fopen(report_file,"w");
        $fwrite(fd,"{\"uart_clks_per_bit\":%0d,\"cycles\":%0d,\"dma_cycles\":%0d,\"micro_cycles\":%0d,\"mismatches\":%0d,\"flash_reads\":%0d,\"flash_programs\":%0d,\"phase_cycles\":[",UART_CLKS_PER_BIT,cycles,dma_cycles,micro_cycles,failures,flash_model.read_ops-reads_start,flash_model.program_ops);
        for(int p=0;p<9;p++)$fwrite(fd,"%s%0d",p?",":"",phase_cycles[p]);
        $fwrite(fd,"],\"phase_words\":[");
        for(int p=0;p<9;p++)$fwrite(fd,"%s%0d",p?",":"",phase_words[p]);
        $fwrite(fd,"]}\n");$fclose(fd);
        if(failures || flash_model.program_ops)$fatal(1,"full network failed: %0d mismatches",failures);
        $display("PASS complete FP8 EGRU+FC: %0d cycles",cycles);$finish;
    end
    initial begin repeat(150000000) @(posedge clk);$fatal(1,"timeout");end
endmodule
