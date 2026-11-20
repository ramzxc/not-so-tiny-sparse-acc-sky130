`timescale 1ns/1ps
module tb_qspi_board_timing;
 parameter real HALF=10, OUT_DELAY=10, IN_DELAY=10, TCO=5.5;
 reg clk=0; always #(HALF) clk=~clk;
 reg rst_n=0,req_valid=0,req_write=0;
 wire req_ready,byte_valid,done,sck,cs_n;
 reg [22:0] req_addr=0;
 reg [3:0] req_bytes=0;
 reg [15:0] req_data=0;
 wire [7:0] read_data;
 wire [3:0] dq_in,dq_out,dq_oe;
 wire msck,mcs; wire [3:0] mout,moe,minput;
 assign #(OUT_DELAY) msck=sck;
 assign #(OUT_DELAY) mcs=cs_n;
 assign #(OUT_DELAY) mout=dq_out;
 assign #(OUT_DELAY) moe=dq_oe;
 assign #(IN_DELAY+TCO) dq_in=minput;
 qpi_engine dut(.*);
 qspi_psram_model #(.DEPTH(256),.MAX_CS_LOW(3000)) mem(.sck(msck),.cs_n(mcs),.dq_out(mout),.dq_oe(moe),.dq_in(minput));
 integer errors=0,checked=0,seen=0;
 realtime last_rise=0,last_fall=0,last_select=0,last_deselect=0,last_dq=0;
 always @(mout or moe) begin
  if(!mcs && moe==15 && last_rise>0 && $realtime-last_rise<2) $fatal(1,"DQ hold");
  last_dq=$realtime;
 end
 always @(negedge mcs) begin
  if(last_deselect>0 && $realtime-last_deselect<18) $fatal(1,"CS recovery");
  last_select=$realtime;
 end
 always @(posedge mcs) begin
  if(last_rise>0 && $realtime-last_rise<3) $fatal(1,"CS hold");
  last_deselect=$realtime;
 end
 always @(posedge msck) if(!mcs) begin
  if($realtime-last_select<2.5) $fatal(1,"CS setup");
  if(moe==15 && $realtime-last_dq<2) $fatal(1,"DQ setup");
  if(last_fall>0 && $realtime-last_fall<6.795) $fatal(1,"SCK low width");
  last_rise=$realtime;
 end
 always @(negedge msck) begin
  if(!mcs && last_rise>0 && $realtime-last_rise<6.795) $fatal(1,"SCK high width");
  last_fall=$realtime;
 end
 reg [7:0] expected[0:255];
 task transaction(input bit wr,input integer addr,input integer len,input reg [15:0] data);
 begin
  @(negedge clk); while(!req_ready) @(negedge clk);
  req_write=wr;req_addr=addr;req_bytes=len;req_data=data;req_valid=1;seen=0;
  @(negedge clk);req_valid=0;
  while(!done) begin
   if(byte_valid) begin
    if(read_data !== expected[addr+seen]) errors++;
    checked++;seen++;
   end
   @(negedge clk);
  end
  if(!wr && seen!=len) $fatal(1,"byte count");
 end endtask
 initial begin
  for(integer i=0;i<256;i++) expected[i]=(i*73+29)&255;
  repeat(4) @(negedge clk); rst_n=1;
  for(integer i=0;i<64;i+=2) transaction(1,i,2,{expected[i+1],expected[i]});
  for(integer i=0;i<64;i++) if(mem.mem[i]!==expected[i]) $fatal(1,"write mismatch");
  for(integer len=1;len<=8;len*=2)
   for(integer i=0;i<32;i++) transaction(0,i,len,0);
  if(errors!=0) $fatal(1,"PSRAM read mismatches: %0d",errors);
  $display("RESULT elapsed_ns=%0.3f checked=%0d errors=%0d half=%0f out=%0f in=%0f tco=%0f",$realtime,checked,errors,HALF,OUT_DELAY,IN_DELAY,TCO);
  $finish;
 end
 initial begin #1000000; $fatal(1,"timeout"); end
endmodule
