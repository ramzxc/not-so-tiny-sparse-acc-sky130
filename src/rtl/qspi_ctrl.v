// Shared PSRAM service: ingress > data/DMA > instruction fetch.
// Own whole transactions and return completion only to the selected requester.
module qspi_ctrl (
    input wire clk,rst_n,
    input wire queue_valid,queue_write,
    input wire [22:0] queue_addr,
    input wire [15:0] queue_data,
    output wire queue_ready,queue_done,queue_byte_valid,
    input wire qspi_req_val,qspi_req_write,
    input wire [22:0] qspi_addr,
    input wire [3:0] qspi_bytes,
    input wire [15:0] qspi_write_data,
    output wire qspi_req_rdy,qspi_done,qspi_byte_valid,
    input wire fetch_valid,
    input wire [22:0] fetch_addr,
    input wire [3:0] fetch_bytes,
    output wire fetch_ready,fetch_done,fetch_byte_valid,bus_busy,
    output wire [7:0] qspi_read_data,
    input wire [3:0] qspi_dq_i,
    output wire sck,ram_a_cs,
    output wire [3:0] dq_out,dq_oe
);
    wire core_bus_ready,core_bus_done,core_bus_byte_valid,queue_bus_busy;
    wire serial_valid,serial_write;
    wire [22:0] serial_addr;
    wire [3:0] serial_bytes;
    wire [15:0] serial_data;
    wire bus_valid,bus_ready,bus_write,bus_done,bus_byte_valid;
    wire [22:0] bus_addr;
    wire [3:0] bus_bytes;
    wire [15:0] bus_data;
    psram_arbiter memory_owner (
        .clk(clk),.rst_n(rst_n),
        .data_valid(qspi_req_val),.data_write(qspi_req_write),.data_addr(qspi_addr),
        .data_bytes(qspi_bytes),.data_wdata(qspi_write_data),.data_ready(qspi_req_rdy),
        .data_done(qspi_done),.data_byte_valid(qspi_byte_valid),
        .fetch_valid(fetch_valid),.fetch_addr(fetch_addr),.fetch_bytes(fetch_bytes),
        .fetch_write(1'b0),.fetch_wdata(16'b0),
        .fetch_ready(fetch_ready),.fetch_done(fetch_done),.fetch_byte_valid(fetch_byte_valid),
        .req_valid(bus_valid),.req_write(bus_write),.req_addr(bus_addr),.req_bytes(bus_bytes),
        .req_data(bus_data),.req_ready(core_bus_ready),.done(core_bus_done),.byte_valid(core_bus_byte_valid),.busy(bus_busy)
    );
    // Existing arbiter owns the core request; a second transaction arbiter
    // grants sparse UART queue traffic priority without interrupting a burst.
    psram_arbiter #(.FETCH_WRITES(1)) ingress_owner (
        .clk(clk),.rst_n(rst_n),
        .data_valid(queue_valid),.data_write(queue_write),.data_addr(queue_addr),
        .data_bytes(4'd2),.data_wdata(queue_data),.data_ready(queue_ready),
        .data_done(queue_done),.data_byte_valid(queue_byte_valid),
        .fetch_valid(bus_valid),.fetch_addr(bus_addr),.fetch_bytes(bus_bytes),
        .fetch_write(bus_write),.fetch_wdata(bus_data),
        .fetch_ready(core_bus_ready),.fetch_done(core_bus_done),.fetch_byte_valid(core_bus_byte_valid),
        .req_valid(serial_valid),.req_write(serial_write),.req_addr(serial_addr),.req_bytes(serial_bytes),
        .req_data(serial_data),.req_ready(bus_ready),.done(bus_done),.byte_valid(bus_byte_valid),.busy(queue_bus_busy)
    );
    qpi_engine serial_memory (
        .clk(clk),.rst_n(rst_n),.req_valid(serial_valid),.req_ready(bus_ready),
        .req_write(serial_write),.req_addr(serial_addr),.req_bytes(serial_bytes),.req_data(serial_data),
        .read_data(qspi_read_data),.byte_valid(bus_byte_valid),.done(bus_done),
        .sck(sck),.cs_n(ram_a_cs),.dq_in(qspi_dq_i),.dq_out(dq_out),.dq_oe(dq_oe)
    );

endmodule

// Private transaction arbiter, reused for both priority levels.
// Whole-transaction ownership: data has priority at each idle boundary.
// Requesters hold their request until ready. Completion goes only to its owner.
module psram_arbiter #(parameter integer FETCH_WRITES=0) (
    input wire clk,rst_n,
    input wire data_valid,data_write,
    input wire [22:0] data_addr,
    input wire [3:0] data_bytes,
    input wire [15:0] data_wdata,
    output wire data_ready,data_done,data_byte_valid,
    input wire fetch_valid,fetch_write,
    input wire [15:0] fetch_wdata,
    input wire [22:0] fetch_addr,
    input wire [3:0] fetch_bytes,
    output wire fetch_ready,fetch_done,fetch_byte_valid,
    output wire req_valid,req_write,
    output wire [22:0] req_addr,
    output wire [3:0] req_bytes,
    output wire [15:0] req_data,
    input wire req_ready,done,byte_valid,
    output reg busy
);
    reg owner_fetch;
    assign req_valid=rst_n && !busy && (data_valid || fetch_valid);
    wire select_data=busy ? !owner_fetch : data_valid;
    assign req_write=select_data ? data_write : (FETCH_WRITES!=0 && fetch_write);
    assign req_addr=select_data ? data_addr : fetch_addr;
    assign req_bytes=select_data ? data_bytes : fetch_bytes;
    assign req_data=(FETCH_WRITES!=0 && !select_data) ? fetch_wdata : data_wdata;
    assign data_ready=rst_n && !busy && req_ready;
    assign fetch_ready=rst_n && !busy && !data_valid && req_ready;
    assign data_byte_valid=busy && !owner_fetch && byte_valid;
    assign fetch_byte_valid=busy && owner_fetch && byte_valid;
    assign data_done=busy && !owner_fetch && done;
    assign fetch_done=busy && owner_fetch && done;
    always @(posedge clk) begin
        if(!rst_n)begin busy<=0;owner_fetch<=0;end
        else begin
            if(req_valid && req_ready)begin busy<=1;owner_fetch<=!data_valid;end
            if(busy && done)busy<=0;
        end
    end
endmodule

// Private wire-protocol engine.
// Board-prepared APS6404L PSRAM A, QPI 0Bh read / 02h write, mode 0.
// One bounded 1..8-byte transaction. No pauses with CS low, no Flash operations.
// Owner holds address/write data until done; reuse those registers instead of copying.
// 8-byte read: 2 command + 6 address + 4 dummy + 16 data SCK cycles.
// SCK=clk/2; board sets QPI before releasing the accelerator reset.
module qpi_engine (
    input wire clk, rst_n,
    input wire req_valid, req_write,
    output wire req_ready,
    input wire [22:0] req_addr,
    input wire [3:0] req_bytes,
    input wire [15:0] req_data,
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
    reg [3:0] bytes_left;
    reg byte_index;
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
                FINISH: begin cs_n<=1;state<=RECOVER;end
                RECOVER: begin done<=1;state<=IDLE;end
                default: begin state<=IDLE;cs_n<=1;sck<=0;end
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(req_ready && req_valid)
        if(req_bytes==0 || req_bytes>8 || (req_write && req_bytes>2) || {1'b0,req_addr}+{20'b0,req_bytes}>24'h800000)
            $fatal(1,"Invalid PSRAM burst");
`endif
endmodule
