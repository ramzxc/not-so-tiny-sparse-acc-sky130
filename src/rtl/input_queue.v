`include "defs/host_defs.vh"
// Experimental fixed-frame UART ingress backed by a reserved PSRAM ring.
// Legacy protocol passes through until F400 after F100 configuration.
// F400 enables raw, padded 16-bit payload words; no per-word credits thereafter.
// Slots are 256 bytes in PSRAM [0x400000,0x800000). Reset exits stream mode.
// Only complete frames become visible to the existing program frontend.
module input_queue #(
    parameter integer SLOT_BITS=14,
    parameter integer RX_FIFO_DEPTH=1
)(
    input wire clk,rst_n,
    input wire [15:0] rx_word,
    input wire rx_valid,
    output wire credit_ready,
    output reg stream_mode,error,
    output wire [15:0] frontend_word,
    output wire frontend_valid,
    input wire frontend_credit_ready,
    input wire stream_start,
    input wire [7:0] frame_words,
    output wire req_valid,req_write,
    output wire [22:0] req_addr,
    output wire [15:0] req_data,
    input wire req_ready,req_done,req_byte_valid,
    input wire [7:0] req_rdata
);
    localparam [2:0] BUS_IDLE=0, WRITE_REQ=1, WRITE_WAIT=2, READ_REQ=3, READ_WAIT=4;
    localparam [2:0] FRAME_WAIT=0, HEADER=1, READ_WORD=2, WORD_WAIT=3, WORD_SEND=4;
    localparam [SLOT_BITS:0] CAPACITY={1'b1,{SLOT_BITS{1'b0}}};
    reg [2:0] bus_state,replay_state;
    reg [6:0] write_index,read_index;
    reg [SLOT_BITS-1:0] write_slot,read_slot;
    reg [SLOT_BITS:0] queued;
    reg [15:0] read_word;
    wire [15:0] write_word;
    wire pending,input_ready;
    // Hold the head until the entire PSRAM write completes. No extra data latch.
    wire write_complete=bus_state==WRITE_WAIT && req_done;
    // Receive storage belongs to this queue, not to the instruction path.
    localparam integer PTR_BITS=RX_FIFO_DEPTH>1 ? $clog2(RX_FIFO_DEPTH) : 1;
    localparam integer COUNT_BITS=$clog2(RX_FIFO_DEPTH+1);
    reg [15:0] rx_words[0:RX_FIFO_DEPTH-1];
    reg [PTR_BITS-1:0] rx_read_ptr,rx_write_ptr;
    reg [COUNT_BITS-1:0] rx_count;
    wire rx_pop=rst_n && stream_mode && !error && write_complete && pending;
    wire rx_push=rst_n && stream_mode && !error && rx_valid && input_ready;
    assign pending=rst_n && rx_count!=0;
    assign input_ready=rst_n && (rx_count<COUNT_BITS'(RX_FIFO_DEPTH) || rx_pop);
    assign write_word=rx_words[rx_read_ptr];
    function [PTR_BITS-1:0] next_rx_ptr;
        input [PTR_BITS-1:0] ptr;
        begin next_rx_ptr=ptr==PTR_BITS'(RX_FIFO_DEPTH-1) ? 0 : ptr+1'b1;end
    endfunction
    always @(posedge clk)begin
        if(!rst_n)begin rx_read_ptr<=0;rx_write_ptr<=0;rx_count<=0;end
        else begin
            if(rx_push)begin rx_words[rx_write_ptr]<=rx_word;rx_write_ptr<=next_rx_ptr(rx_write_ptr);end
            if(rx_pop)rx_read_ptr<=next_rx_ptr(rx_read_ptr);
            case({rx_push,rx_pop})
                2'b10:rx_count<=rx_count+1'b1;
                2'b01:rx_count<=rx_count-1'b1;
                default:begin end
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(RX_FIFO_DEPTH<1)$fatal(1,"RX_FIFO_DEPTH must be at least one");
        if(SLOT_BITS<1 || SLOT_BITS>14)$fatal(1,"SLOT_BITS must fit the reserved 4 MiB ring");
    end
`endif
    wire push_frame=bus_state==WRITE_WAIT && req_done && {1'b0,write_index}+8'd1==frame_words;
    wire pop_frame=replay_state==WORD_SEND && {1'b0,read_index}+8'd1==frame_words;
    // Replay emits a delivery pulse one cycle after observing credit readiness.
    // Do not replace this with a same-cycle valid && ready handshake.
    assign credit_ready=!stream_mode && !error && frontend_credit_ready;
    assign frontend_word=!stream_mode ? rx_word : replay_state==HEADER ? `HOST_FRAME : read_word;
    assign frontend_valid=rst_n && !error && (!stream_mode ? rx_valid :
        replay_state==HEADER || replay_state==WORD_SEND);
    assign req_valid=rst_n && !error && (bus_state==WRITE_REQ || bus_state==READ_REQ);
    assign req_write=bus_state==WRITE_REQ || bus_state==WRITE_WAIT;
    // Addition zero-extends the parameterized slot field to the physical address.
    assign req_addr=23'h400000 + 23'(req_write ? {write_slot,write_index,1'b0} : {read_slot,read_index,1'b0});
    assign req_data=write_word;
    always @(posedge clk) begin
        if(!rst_n)begin
            stream_mode<=0;error<=0;
            bus_state<=BUS_IDLE;replay_state<=FRAME_WAIT;
            read_word<=0;write_index<=0;read_index<=0;
            write_slot<=0;read_slot<=0;queued<=0;
        end else if(!error)begin
            if(!stream_mode)begin
                if(stream_start)stream_mode<=1;
            end else begin
                // Raw UART cannot be stalled. Report actual FIFO overflow explicitly.
                if(rx_valid && !input_ready)error<=1;
                case({push_frame,pop_frame})
                    2'b10:queued<=queued+1'b1;
                    2'b01:queued<=queued-1'b1;
                    default:begin end
                endcase
                case(bus_state)
                    // A full ring must still allow replay to free a slot.
                    BUS_IDLE: if(pending && queued<CAPACITY)bus_state<=WRITE_REQ;
                        else if(replay_state==READ_WORD)bus_state<=READ_REQ;
                    WRITE_REQ: if(req_ready)bus_state<=WRITE_WAIT;
                    WRITE_WAIT: if(req_done)begin
                        bus_state<=BUS_IDLE;
                        if(push_frame)begin write_index<=0;write_slot<=write_slot+1'b1;end
                        else write_index<=write_index+1'b1;
                    end
                    READ_REQ: if(req_ready)bus_state<=READ_WAIT;
                    READ_WAIT: begin
                        if(req_byte_valid)read_word<={req_rdata,read_word[15:8]};
                        if(req_done)begin bus_state<=BUS_IDLE;replay_state<=WORD_WAIT;end
                    end
                    default:error<=1;
                endcase
                case(replay_state)
                    FRAME_WAIT: if(queued!=0 && frontend_credit_ready)replay_state<=HEADER;
                    HEADER: replay_state<=READ_WORD;
                    READ_WORD:begin end
                    WORD_WAIT: if(frontend_credit_ready)replay_state<=WORD_SEND;
                    WORD_SEND:begin
                        if(pop_frame)begin read_index<=0;read_slot<=read_slot+1'b1;replay_state<=FRAME_WAIT;end
                        else begin read_index<=read_index+1'b1;replay_state<=READ_WORD;end
                    end
                    default:error<=1;
                endcase
            end
        end
    end
endmodule
