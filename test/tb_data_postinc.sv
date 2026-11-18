`timescale 1ns/1ps
module tb_data_postinc;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [15:0] instruction=0;
    reg valid=0, mem_ready=1, read_valid=0;
    reg [31:0] read_data=0;
    wire ready, ren, wen, accumulate, operand_valid, weight;
    wire [23:0] addr;
    wire [1:0] device;
    wire [31:0] write_data, operand;
    data_ctrl dut(clk,rst_n,instruction,valid,ready,32'h40003c00,1'b1,
        operand,operand_valid,weight,mem_ready,ren,wen,accumulate,addr,device,
        write_data,read_data,read_valid, , , , );
    task tick; @(posedge clk); #1; endtask
    task issue(input [15:0] inst);
        @(negedge clk); instruction=inst;valid=1;
        #1; if (!ready) $fatal(1,"instruction not ready");
        tick(); @(negedge clk); valid=0;
    endtask
    task address(input [23:0] a);
        issue(16'h2000|{4'b0,a[11:0]});issue(16'h3000|{4'b0,a[23:12]});
    endtask
    task expect_addr(input [23:0] a);
        if(addr!==a) $fatal(1,"address %h expected %h",addr,a);
    endtask
    task read_complete(input [23:0] before_addr, after_addr);
        // Stall acceptance, then stall response; neither may advance the address.
        mem_ready=0;
        repeat(4) begin tick();expect_addr(before_addr);end
        @(negedge clk);mem_ready=1;tick();
        @(negedge clk);mem_ready=0;
        repeat(4) begin tick();expect_addr(before_addr);end
        @(negedge clk);read_valid=1;tick();expect_addr(before_addr);
        @(negedge clk);read_valid=0;mem_ready=1;tick();expect_addr(after_addr);
        repeat(3) begin tick();expect_addr(after_addr);end
    endtask
    initial begin
        repeat(2) tick();@(negedge clk);rst_n=1;tick();
        address(24'h000ffc);issue(16'h4100);read_complete(24'h000ffc,24'h001000);
        issue(16'h4000);read_complete(24'h001000,24'h001000);
        // Previous input was zero: sparse weight read is skipped but advances once.
        issue(16'h8c00);issue(16'h4100);
        if(ren||wen) $fatal(1,"sparse request escaped");
        tick();expect_addr(24'h001004);repeat(3) tick();expect_addr(24'h001004);
        // Element-level zero mask: [0,1] skips cur=0, but cur=1 must read.
        issue(16'h8000);address(0);read_data=32'h3c000000;
        issue(16'h4100);read_complete(0,4);
        issue(16'h8d00);issue(16'h4100);
        if(ren||wen) $fatal(1,"selected zero should skip");
        tick();expect_addr(8);
        issue(16'h8f00);issue(16'h4100);
        if(!ren) $fatal(1,"selected nonzero should read");
        read_complete(8,12);
        issue(16'h8d00);
        // Overflow remains invalid, never wraps to zero.
        address(24'hfffffc);issue(16'h4100);tick();expect_addr(24'hffffff);
        issue(16'h4100);tick();expect_addr(24'hffffff);
        // Reset during a pending read cancels the increment and clears address.
        issue(16'h8000);address(24'd100);issue(16'h4500);mem_ready=0;tick();
        @(negedge clk);rst_n=0;tick();expect_addr(0);
        $display("PASS post-increment stalls, sparse skip, carry, overflow and reset");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
