"""Exercise every usable word of generated 1RW behavioral models."""
from pathlib import Path
import subprocess,sys
out=Path(sys.argv[1]).resolve();n=int(sys.argv[2]);name=f'tt_sram_1rw_64x{n}_sky130'
tb=out/'tb_model.sv'
tb.write_text(f'''module tb;
reg clk=0, csb=1, web=1;
reg [{(n-1).bit_length()-1}:0] addr=0;
reg [63:0] din=0;
wire [64:0] dout;
reg [63:0] expected[0:{n-1}];
{name} #(.VERBOSE(0)) dut(.clk0(clk),.csb0(csb),.web0(web),.spare_wen0(1'b0),.addr0(addr),.din0({{1'b0,din}}),.dout0(dout));
task cycle; begin #5; clk=1; #5; clk=0; #5; end endtask
integer i,p;
initial begin
for(p=0;p<4;p=p+1) begin
 for(i=0;i<{n};i=i+1) begin
  case(p)
  0: expected[i]=64'h0;
  1: expected[i]=64'hffffffffffffffff;
  2: expected[i]=64'haaaa5555aaaa5555 ^ i;
  3: expected[i]={{$random,$random}};
  endcase
  csb=0;web=0;addr=i;din=expected[i];cycle;
 end
 for(i={n-1};i>=0;i=i-1) begin
  csb=0;web=1;addr=i;cycle;
  if(dout[63:0] !== expected[i]) $fatal(1,"read mismatch address %0d",i);
  csb=1;web=0;din=~expected[i];cycle;
  csb=0;web=1;cycle;
  if(dout[63:0] !== expected[i]) $fatal(1,"disabled write modified address %0d",i);
 end
end
$display("PASS: {n} words, four patterns, disabled writes, reverse reads");$finish;
end
endmodule
''')
exe=out/'tb_model.vvp'
subprocess.run(['iverilog','-g2012','-s','tb','-o',str(exe),str(tb),str(out/(name+'.v'))],check=True)
r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,check=True)
(out/'behavioral_test.log').write_text(r.stdout+r.stderr);print(r.stdout)
