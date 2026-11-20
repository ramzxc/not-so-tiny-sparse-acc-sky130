`timescale 1ns/1ps
module tb_uart_queue_fifo;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,rx_valid=0,frontend_ready=0,req_ready=0,req_done=0;
    reg [15:0] rx_word=0;
    wire stream_mode,error,req_valid,req_write,frontend_valid;
    wire [22:0] req_addr;
    wire [15:0] req_data,frontend_word;
    input_queue #(.SLOT_BITS(2),.RX_FIFO_DEPTH(4)) dut (
        .clk(clk),.rst_n(rst_n),.rx_word(rx_word),.rx_valid(rx_valid),.rx_ready(),
        .stream_mode(stream_mode),.error(error),.frontend_word(frontend_word),
        .frontend_valid(frontend_valid),.frontend_ready(frontend_ready),
        .req_valid(req_valid),.req_write(req_write),.req_addr(req_addr),.req_data(req_data),
        .req_ready(req_ready),.req_done(req_done),.req_byte_valid(1'b0),.req_rdata(8'b0)
    );
    task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
    task send(input [15:0] word_in); begin rx_word=word_in;rx_valid=1;tick();rx_valid=0;tick();end endtask
    task setup; begin
        rst_n=0;rx_valid=0;req_ready=0;req_done=0;frontend_ready=1;tick();tick();rst_n=1;
        send(16'hf100);send(0);send(0);send(0);send(0);send(2);send(16'hf400);
        frontend_ready=0;
        if(!stream_mode || error)$fatal(1,"configuration failed");
    end endtask
    task write_head(input [15:0] expected,input integer slot,input bit replace_head);
        integer timeout;
        begin
            timeout=0;
            while(!req_valid)begin tick();timeout=timeout+1;if(timeout>50)$fatal(1,"no write");end
            if(!req_write || req_data!==expected || req_addr!==(23'h400000+slot*256))
                $fatal(1,"write order/address mismatch");
            req_ready=1;tick();req_ready=0;
            repeat(5)begin
                if(req_data!==expected)$fatal(1,"head changed before completion");
                tick();
            end
            req_done=1;
            if(replace_head)begin rx_valid=1;rx_word=16'h5555;end
            tick();req_done=0;rx_valid=0;tick();
            if(error)$fatal(1,"unexpected overflow");
        end
    endtask
    initial begin
        setup();
        // QSPI is blocked for four complete words. FIFO must retain their order.
        send(16'h1111);send(16'h2222);send(16'h3333);send(16'h4444);
        repeat(20)tick();
        if(error || dut.rx_count!=4)$fatal(1,"blocked receive failed");
        // Full FIFO accepts a new word on the same edge its head retires.
        write_head(16'h1111,0,1);
        write_head(16'h2222,1,0);write_head(16'h3333,2,0);write_head(16'h4444,3,0);
        repeat(10)tick();
        if(error || req_valid || dut.queued!=4 || dut.rx_count!=1)
            $fatal(1,"full ring must retain FIFO tail without overwriting");
        // Permit replay; its final delivery frees one ring slot.
        frontend_ready=1;
        wait(req_valid); @(negedge clk);
        if(req_write)$fatal(1,"full ring must replay before writing");
        req_ready=1;tick();req_ready=0;req_done=1;tick();req_done=0;
        write_head(16'h5555,0,0);
        setup();
        send(1);send(2);send(3);send(4);send(5);
        if(!error)$fatal(1,"FIFO overflow not reported");
        repeat(5)tick();if(!error)$fatal(1,"error not sticky");
        setup();if(dut.rx_count!=0)$fatal(1,"reset failed");
        $display("PASS: FIFO stall/order, simultaneous pop/push, ring full/recovery, overflow/reset");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout");end
endmodule
