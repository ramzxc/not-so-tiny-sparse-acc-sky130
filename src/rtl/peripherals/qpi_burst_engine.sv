module qpi_burst_engine (
    input wire clk, rst_n,
    input wire req_valid, req_write,
    output wire req_ready,
    input wire [22:0] req_addr,
    input wire [6:0] req_bytes,
    input wire [63:0] req_data,
    input wire read_hold, read_cut,
    output reg [7:0] read_data,
    output reg byte_valid,
    output reg done,
    output reg sck, cs_n,
    input wire [3:0] dq_in,
    output reg [3:0] dq_out, dq_oe
);
    localparam [2:0] IDLE=0, SELECT=1, COMMAND=2, ADDRESS=3,
        DUMMY=4, DATA=5, FINISH=6, RECOVER=7;
    reg [2:0] state;
    reg write_reg;
    reg [6:0] bytes_left;
    reg [2:0] byte_index;
    reg [2:0] nibble_left;
    reg low_nibble;
    wire [7:0] command = write_reg ? 8'h02 : 8'h0b;
    wire [23:0] address_word = {1'b0,req_addr};
    assign req_ready = rst_n && state==IDLE;
    always @(*) begin
        dq_out=0; dq_oe=0;
        case(state)
            COMMAND: begin dq_oe=4'hf; dq_out=nibble_left!=0 ? command[7:4] : command[3:0]; end
            ADDRESS: begin dq_oe=4'hf; dq_out=address_word[nibble_left*4 +: 4]; end
            DATA: if(write_reg) begin
                dq_oe=4'hf;
                dq_out=low_nibble ? req_data[byte_index*8 +: 4] : req_data[byte_index*8+4 +: 4];
            end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; sck<=0; cs_n<=1; done<=0; byte_valid<=0; read_data<=0;
            write_reg<=0; bytes_left<=0;
            byte_index<=0; nibble_left<=0; low_nibble<=0;
        end else begin
            done<=0;byte_valid<=0;
            case(state)
                IDLE: if(req_valid) begin
                    write_reg<=req_write; bytes_left<=req_bytes;
                    byte_index<=0; low_nibble<=0; read_data<=0;
                    state<=SELECT;
                end
                SELECT: begin cs_n<=0; sck<=0; nibble_left<=1; state<=COMMAND; end
                COMMAND,ADDRESS,DUMMY,DATA: begin
                    // At a completed byte, SCK is low. The controller can hold
                    // one beat briefly or close this read before the next byte.
                    if (state==DATA && !write_reg && !sck && !low_nibble && read_cut)
                        state<=FINISH;
                    else if (!(state==DATA && !write_reg && !sck && !low_nibble && read_hold)) begin
                        sck<=!sck;
                        if(!sck) begin
                            // Read on the next core edge: allow a full SCK period
                            // for the falling-edge PSRAM data to return through IO.
                        end else if(state==DATA) begin
                            if(!write_reg) begin
                                if(low_nibble)read_data[3:0]<=dq_in;
                                else read_data[7:4]<=dq_in;
                            end
                            if(!low_nibble)low_nibble<=1;
                            else begin
                                if(!write_reg)byte_valid<=1;
                                if(bytes_left==1)state<=FINISH;
                                else begin bytes_left<=bytes_left-1'b1;byte_index<=byte_index+1'b1;low_nibble<=0;end
                            end
                        end else if(nibble_left!=0)nibble_left<=nibble_left-1'b1;
                        else case(state)
                            COMMAND: begin nibble_left<=5;state<=ADDRESS;end
                            ADDRESS: if(write_reg)state<=DATA;else begin nibble_left<=3;state<=DUMMY;end
                            DUMMY: state<=DATA;
                            default: begin end
                        endcase
                    end
                end
                FINISH: begin cs_n<=1;state<=RECOVER;end
                RECOVER: begin done<=1;state<=IDLE;end
                default: begin state<=IDLE;cs_n<=1;sck<=0;end
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(req_ready && req_valid)
        if(req_bytes==0 || req_bytes>64 || (req_write && req_bytes>8) ||
           {1'b0,req_addr}+{17'b0,req_bytes}>24'h800000)
            $fatal(1,"Invalid PSRAM burst");
`endif
endmodule
