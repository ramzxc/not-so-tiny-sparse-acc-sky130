`include "defs/defs.vh"
`include "defs/mem_defs.vh"
// Ordinary vectors remain two bytes. DMA fills the existing SRAM row buffer
// through bounded 2..8-byte QPI reads, then commits one row. No added data cache.
module mem_itf (
    input wire clk,rst_n,read_en,write_en,write_accumulate,
    input wire read_burst,read_continue,
    input wire copy_en,
    input wire [23:0] copy_source,
    input wire [9:0] copy_destination,
    input wire [2:0] copy_vectors,
    output reg copy_done,
    output wire rdy,
    input wire [23:0] addr,
    input wire [1:0] device,
    input wire [15:0] write_data,
    output reg [15:0] read_data,
    output reg read_data_val,error,
    output wire qspi_req_val,
    input wire qspi_req_rdy,
    output wire qspi_req_write,
    output wire [22:0] qspi_req_addr,
    output wire [3:0] qspi_req_bytes,
    output wire [15:0] qspi_req_data,
    input wire [7:0] qspi_read_data,
    input wire qspi_byte_valid,qspi_done
);
    `include "defs/fp8_math.vh"
    typedef enum logic [3:0] {IDLE,EXTERNAL_SEND,EXTERNAL_WAIT,SRAM_READ,SRAM_WAIT,
        ADD_LOW,ADD_HIGH,SRAM_WRITE,SRAM_COMMIT} state_t;
    state_t state;
    reg [23:0] saved_addr;
    reg [15:0] saved_data,old_vector;
    reg saved_write,saved_accumulate,copy_active;
    reg [2:0] copy_byte;
    wire [24:0] copy_end={1'b0,copy_source}+{21'b0,copy_vectors,1'b0};
    reg [63:0] write_word;
    wire [63:0] macro_data;
    wire [1:0] vector_slot=saved_addr[2:1];
    wire high_lane=state==ADD_HIGH;
    wire [7:0] sum=fp8_add(old_vector[high_lane*8 +: 8],saved_data[high_lane*8 +: 8]);
    assign rdy=rst_n && state==IDLE;
    assign qspi_req_val=rst_n && state==EXTERNAL_SEND;
    assign qspi_req_write=saved_write && !copy_active;
    assign qspi_req_addr=copy_active ? copy_source[22:0] : saved_addr[22:0];
    assign qspi_req_bytes=copy_active ? {copy_vectors,1'b0} : 4'd2;
    assign qspi_req_data=saved_data;
    shared_sram #(.SRAM_BYTES(1024)) memory (
        .clk(clk),.enable(rst_n && (state==SRAM_READ || state==SRAM_WRITE)),
        .write(state==SRAM_WRITE),.addr(saved_addr[9:3]),.wdata(write_word),.rdata(macro_data)
    );
    always @(posedge clk)begin
        if(!rst_n)begin
            state<=IDLE;saved_addr<=0;saved_data<=0;old_vector<=0;write_word<=0;
            copy_active<=0;copy_byte<=0;copy_done<=0;saved_write<=0;saved_accumulate<=0;read_data<=0;read_data_val<=0;error<=0;
        end else begin
            read_data_val<=0;copy_done<=0;
            case(state)
                IDLE:if(copy_en)begin
                    if(read_en || write_en || copy_vectors==0 || copy_vectors>4 ||
                       copy_destination[0] || {1'b0,copy_destination[2:1]}+copy_vectors>4 ||
                       copy_end>25'h0800000)begin error<=1;copy_done<=1;end
                    else begin
                        saved_addr<={14'b0,copy_destination};saved_write<=1;saved_accumulate<=0;
                        copy_active<=1;copy_byte<=copy_destination[2:0];
                        state<=copy_vectors==4 ? EXTERNAL_SEND : SRAM_READ;
                    end
                end else if(read_en || write_en)begin
                    if((read_en && write_en) || device[1] ||
                        (device==`MEM_SRAM && (addr>=1024 || addr[0])) ||
                        (device==`MEM_PSRAM && (addr>24'h7ffffe || write_accumulate)) ||
                        (write_accumulate && !write_en))begin
                        error<=1;read_data<=0;read_data_val<=read_en;
                    end else begin
                        saved_addr<=addr;saved_data<=write_data;saved_write<=write_en;
                        saved_accumulate<=write_accumulate;
                        state<=device==`MEM_SRAM ? SRAM_READ : EXTERNAL_SEND;
                    end
                end
                EXTERNAL_SEND:if(qspi_req_rdy)state<=EXTERNAL_WAIT;
                EXTERNAL_WAIT:begin
                    if(qspi_byte_valid)begin
                        if(copy_active)begin
                            write_word[copy_byte*8 +: 8]<=qspi_read_data;copy_byte<=copy_byte+1'b1;
                        end else if(!saved_write)read_data<={qspi_read_data,read_data[15:8]};
                    end
                    if(qspi_done)begin
                        if(copy_active)state<=SRAM_WRITE;
                        else begin read_data_val<=!saved_write;state<=IDLE;end
                    end
                end
                SRAM_READ:state<=SRAM_WAIT;
                SRAM_WAIT:begin
                    if(copy_active)begin write_word<=macro_data;state<=EXTERNAL_SEND;end
                    else if(!saved_write)begin
                        read_data<=macro_data[vector_slot*16 +: 16];read_data_val<=1;state<=IDLE;
                    end else begin
                        old_vector<=macro_data[vector_slot*16 +: 16];write_word<=macro_data;
                        if(saved_accumulate)state<=ADD_LOW;
                        else begin write_word[vector_slot*16 +: 16]<=saved_data;state<=SRAM_WRITE;end
                    end
                end
                ADD_LOW:begin write_word[vector_slot*16 +: 8]<=sum;state<=ADD_HIGH;end
                ADD_HIGH:begin write_word[vector_slot*16+8 +: 8]<=sum;state<=SRAM_WRITE;end
                SRAM_WRITE:state<=SRAM_COMMIT;
                SRAM_COMMIT:begin
                    state<=IDLE;
                    if(copy_active)begin copy_done<=1;copy_active<=0;end
                end
                default:state<=IDLE;
            endcase
        end
    end
    // Legacy vector-stream hints are unused: copy_en/copy_vectors now request
    // row-bounded chunks without pause timers or an extra DMA cache.
    wire _unused=&{read_burst,read_continue,1'b0};
endmodule
