// Experimental fixed-frame UART ingress backed by a reserved PSRAM ring.
// Legacy protocol passes through until F400 after F100 configuration.
// F400 enables raw, padded 16-bit payload words; no per-word credits thereafter.
// Slots are 256 bytes in PSRAM [0x400000,0x800000). Reset exits stream mode.
// Only complete frames become visible to the existing program frontend.
module uart_psram_queue #(
    parameter integer SLOT_BITS=14
)(
    input wire clk,rst_n,
    input wire [15:0] rx_word,
    input wire rx_valid,
    output wire rx_ready,
    output reg stream_mode,error,
    output wire [15:0] frontend_word,
    output wire frontend_valid,
    input wire frontend_ready,
    output wire req_valid,req_write,
    output wire [22:0] req_addr,
    output wire [15:0] req_data,
    input wire req_ready,req_done,req_byte_valid,
    input wire [7:0] req_rdata
);
    localparam [2:0] BUS_IDLE=0, WRITE_REQ=1, WRITE_WAIT=2, READ_REQ=3, READ_WAIT=4;
    localparam [2:0] FRAME_WAIT=0, HEADER=1, READ_WORD=2, WORD_WAIT=3, WORD_SEND=4;
    localparam [SLOT_BITS:0] CAPACITY={1'b1,{SLOT_BITS{1'b0}}};
    reg [2:0] bus_state,replay_state,config_left;
    reg configured,pending;
    reg [7:0] frame_words;
    reg [6:0] write_index,read_index;
    reg [SLOT_BITS-1:0] write_slot,read_slot;
    reg [SLOT_BITS:0] queued;
    reg [15:0] write_word,read_word;
    wire enable_stream=!stream_mode && config_left==0 && rx_word==16'hf400;
    wire push_frame=bus_state==WRITE_WAIT && req_done && {1'b0,write_index}+8'd1==frame_words;
    wire pop_frame=replay_state==WORD_SEND && {1'b0,read_index}+8'd1==frame_words;
    assign rx_ready=!stream_mode && !error && frontend_ready;
    assign frontend_word=!stream_mode ? rx_word : replay_state==HEADER ? 16'hf200 : read_word;
    assign frontend_valid=rst_n && !error && (!stream_mode ? rx_valid && !enable_stream :
        replay_state==HEADER || replay_state==WORD_SEND);
    assign req_valid=rst_n && !error && (bus_state==WRITE_REQ || bus_state==READ_REQ);
    assign req_write=bus_state==WRITE_REQ || bus_state==WRITE_WAIT;
    // Addition zero-extends the parameterized slot field to the physical address.
    assign req_addr=23'h400000 + (req_write ? {write_slot,write_index,1'b0} : {read_slot,read_index,1'b0});
    assign req_data=write_word;
    always @(posedge clk) begin
        if(!rst_n)begin
            stream_mode<=0;error<=0;configured<=0;config_left<=0;frame_words<=0;
            bus_state<=BUS_IDLE;replay_state<=FRAME_WAIT;pending<=0;
            write_word<=0;read_word<=0;write_index<=0;read_index<=0;
            write_slot<=0;read_slot<=0;queued<=0;
        end else if(!error)begin
            if(!stream_mode)begin
                if(rx_valid)begin
                    if(config_left!=0)begin
                        config_left<=config_left-1'b1;
                        if(config_left==1)begin
                            // Full input validation is still owned by program_ctrl.
                            configured<=rx_word!=0 && rx_word<=256;
                            frame_words<=8'((rx_word+16'd1)>>1);
                        end
                    end else if(rx_word==16'hf100)begin config_left<=5;configured<=0;end
                    else if(enable_stream)begin
                        if(!configured || !frontend_ready)error<=1;
                        else stream_mode<=1;
                    end
                end
            end else begin
                // Receiver shift register is not stable during the next UART word.
                if(rx_valid)begin
                    if(pending || queued==CAPACITY)error<=1;
                    else begin write_word<=rx_word;pending<=1;end
                end
                case({push_frame,pop_frame})
                    2'b10:queued<=queued+1'b1;
                    2'b01:queued<=queued-1'b1;
                    default:begin end
                endcase
                case(bus_state)
                    BUS_IDLE: if(pending)bus_state<=WRITE_REQ;
                        else if(replay_state==READ_WORD)bus_state<=READ_REQ;
                    WRITE_REQ: if(req_ready)bus_state<=WRITE_WAIT;
                    WRITE_WAIT: if(req_done)begin
                        pending<=0;bus_state<=BUS_IDLE;
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
                    FRAME_WAIT: if(queued!=0 && frontend_ready)replay_state<=HEADER;
                    HEADER: replay_state<=READ_WORD;
                    READ_WORD:begin end
                    WORD_WAIT: if(frontend_ready)replay_state<=WORD_SEND;
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
