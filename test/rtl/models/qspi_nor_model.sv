`timescale 1ns/1ps
// Independent pin-level functional NOR model for the chosen W25Q128JV profile.
// Not vendor timing/signoff. Data persist across accelerator resets.
module qspi_nor_model #(
    parameter int DEPTH=65536,
    parameter bit BOARD_PREPARED=0,
    parameter time PROGRAM_TIME=1000ns, ERASE_TIME=3000ns
)(input logic clk,sck,cs_n, input logic [3:0] dq_out,dq_oe,
  output logic [3:0] dq_in,
  input logic stuck_busy,reject_wren,ignore_qe);
    logic [7:0] mem[0:DEPTH-1];
    logic wel=0;
    logic [7:0] sr2=(BOARD_PREPARED ? 8'h02 : 8'h00),opcode=0,shift=0,out_byte=0,program_data[256];
    logic [23:0] addr=0;
    integer phase=0,bits=0,dummy=0,read_addr=0,out_index=0,program_count=0;
    integer program_ops=0,erase_ops=0,read_ops=0;
    time busy_until=0;
    logic busy;
    always @(clk or stuck_busy or busy_until) busy=stuck_busy || $time<busy_until;
    // phase: 0=opcode,1=address,2=dummy,3=quad read,4=status,
    // 5=quad program,6=SR2 write,7=command-only/wait-CS.
    initial begin for(int i=0;i<DEPTH;i++) mem[i]=8'hff; dq_in=4'b1111; end
    always @(negedge cs_n) begin
        phase=0; bits=0; shift=0; opcode=0; addr=0; program_count=0; out_index=0; dq_in=4'b1111;
    end
    always @(posedge sck) if(!cs_n) begin
        case(phase)
            0: begin
                if(dq_oe[0]!==1) $fatal(1,"opcode MOSI not driven");
                shift={shift[6:0],dq_out[0]}; bits++;
                if(bits==8) begin
                    opcode=shift; bits=0;
                    if(BOARD_PREPARED && (opcode==8'h35 || opcode==8'h31 || opcode==8'h20))
                        $fatal(1,"chip issued board-owned initialization/erase opcode %h",opcode);
                    if(busy && opcode!=8'h05) $fatal(1,"command %h while NOR busy",opcode);
                    case(opcode)
                        8'h06: phase=7;
                        8'h05,8'h35: begin phase=4; out_index=7; end
                        8'h6b,8'h32,8'h20: phase=1;
                        8'h31: phase=6;
                        default: $fatal(1,"unsupported NOR opcode %h",opcode);
                    endcase
                end
            end
            1: begin
                addr={addr[22:0],dq_out[0]}; bits++;
                if(bits==24) begin
                    bits=0;
                    if(addr>=DEPTH) $fatal(1,"model address out of range %h",addr);
                    case(opcode)
                        8'h6b: begin
                            if(!sr2[1]) $fatal(1,"quad read before QE");
                            phase=2; dummy=0; read_addr=int'(addr); read_ops++;
                        end
                        8'h32: begin if(!sr2[1] || !wel) $fatal(1,"program requires QE and WEL"); phase=5; end
                        8'h20: begin if(!wel || addr[11:0]!=0) $fatal(1,"invalid erase"); phase=7; end
                        default: $fatal(1,"address phase");
                    endcase
                end
            end
            2: begin dummy++; if(dummy==8) begin phase=3; out_index=1; end end
            3: begin
                if(dq_oe!=0) $fatal(1,"quad read bus contention");
                if(out_index==0) begin read_addr++; out_index=1; end else out_index--;
            end
            4: begin
                if(dq_oe[1]) $fatal(1,"status bus contention");
                if(out_index==0) out_index=7; else out_index--;
            end
            5: begin
                if(dq_oe!=4'hf) $fatal(1,"quad program pins not driven");
                shift={shift[3:0],dq_out}; bits++;
                if(bits==2) begin
                    if(program_count>=256 || int'(addr[7:0])+program_count>=256) $fatal(1,"page crossing/wrap");
                    program_data[program_count]=shift; program_count++; bits=0;
                end
            end
            6: begin shift={shift[6:0],dq_out[0]}; bits++; end
            default: ;
        endcase
    end
    always @(negedge sck) if(!cs_n) begin
        dq_in=4'b1111;
        if(phase==3) begin
            if(read_addr>=DEPTH) $fatal(1,"read exceeds model");
            dq_in=out_index==1?mem[read_addr][7:4]:mem[read_addr][3:0];
        end else if(phase==4) begin
            if(out_index==7) out_byte=opcode==8'h05 ? {6'b0,wel,busy}:sr2;
            dq_in[1]=out_byte[out_index];
        end
    end
    always @(posedge cs_n) begin
        dq_in=4'b1111;
        case(opcode)
            8'h06: if(!busy && !reject_wren) wel=1;
            8'h31: if(phase==6 && bits==8) begin
                if(!wel) $fatal(1,"status write without WEL");
                if(!ignore_qe) sr2=shift;
                wel=0; busy_until=$time+PROGRAM_TIME;
            end
            8'h32: if(program_count!=0) begin
                if(bits!=0) $fatal(1,"program ended mid-byte");
                for(int i=0;i<program_count;i++) begin
                    if((mem[int'(addr)+i]&program_data[i])!==program_data[i]) $fatal(1,"program needs erase at %h",int'(addr)+i);
                    mem[int'(addr)+i]=mem[int'(addr)+i]&program_data[i];
                end
                wel=0; busy_until=$time+PROGRAM_TIME; program_ops++;
            end
            8'h20: if(phase==7) begin
                for(int i=0;i<4096;i++) mem[int'(addr)+i]=8'hff;
                wel=0; busy_until=$time+ERASE_TIME; erase_ops++;
            end
            default: ;
        endcase
    end
endmodule
