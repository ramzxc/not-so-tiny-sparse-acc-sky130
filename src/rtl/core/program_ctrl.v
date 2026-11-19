// UART words configure a replayable PSRAM program and supply raw input frames.
// 8N1, low byte first, one 01h READY credit per word. Commands are not UART data.
// F100 + base_lo16 + base_hi8 + word_count + SRAM_input_base + input_byte_count.
// F200 + ceil(input_byte_count/2) payload words: commit input then run program.
// F300: run the configured program without changing SRAM input.
// No branches/loops here: MICRO still performs its existing generic operations.
module program_ctrl (
    input wire clk,rst_n,
    input wire [15:0] rx_word,
    input wire rx_valid,
    output wire rx_ready,
    output reg error,
    output wire busy,
    input wire units_idle, memory_error,
    output wire [15:0] inst,
    output wire inst_valid,
    input wire inst_ready,
    output wire fetch_valid,
    output wire [22:0] fetch_addr,
    output wire [3:0] fetch_bytes,
    input wire fetch_ready,fetch_done,
    input wire [7:0] fetch_data,
    input wire fetch_byte_valid,
    output wire input_write,
    output wire [9:0] input_addr,
    output wire [15:0] input_data,
    input wire mem_ready
);
    localparam [3:0] IDLE=0, CONFIG=1, CHECK=2, INPUT=3, WRITE=4,
        WRITE_WAIT=5, START=6, FETCH=7, FETCH_WAIT=8, ISSUE=9, DRAIN=10;
    reg [3:0] state;
    reg [2:0] config_index;
    reg [23:0] program_base,pc;
    reg [15:0] program_words,words_left;
    reg [9:0] input_base;
    reg [10:0] input_bytes;
    reg [63:0] instruction_buffer;
    reg [2:0] buffered_words;
    reg configured;
    wire [24:0] program_end={1'b0,program_base}+{8'b0,program_words,1'b0};
    wire [11:0] input_end={2'b0,input_base}+{1'b0,input_bytes}+{11'b0,input_bytes[0]};
    assign busy=state!=IDLE && state!=CONFIG && state!=CHECK;
    assign rx_ready=rst_n && !error && !rx_valid && (state==IDLE || state==CONFIG || state==INPUT);
    assign fetch_valid=rst_n && !error && !memory_error && state==FETCH;
    assign fetch_addr=pc[22:0];
    assign fetch_bytes=words_left>=4 ? 4'd8 : {words_left[2:0],1'b0};
    wire [1:0] word_slot=buffered_words[1:0]-2'd1;
    wire [15:0] buffered_inst=instruction_buffer[word_slot*16 +: 16];
    assign inst={buffered_inst[7:0],buffered_inst[15:8]};
    assign inst_valid=rst_n && !error && !memory_error && state==ISSUE;
    assign input_write=rst_n && !error && state==WRITE;
    assign input_addr=pc[9:0];
    assign input_data=words_left==1 ? {8'b0,rx_word[7:0]} : rx_word;
    always @(posedge clk) begin
        if(!rst_n)begin
            state<=IDLE;config_index<=0;program_base<=0;pc<=0;program_words<=0;words_left<=0;
            input_base<=0;input_bytes<=0;
            instruction_buffer<=0;buffered_words<=0;configured<=0;error<=0;
        end else if(memory_error)begin error<=1;state<=IDLE;end
        else if(!error)begin
            if(rx_valid && state!=IDLE && state!=CONFIG && state!=INPUT)error<=1;
            case(state)
                IDLE: if(rx_valid)begin
                    if(rx_word==16'hf100)begin configured<=0;config_index<=0;state<=CONFIG;end
                    else if(rx_word==16'hf200 && configured && input_bytes!=0)begin
                        pc<={14'b0,input_base};words_left<={5'b0,input_bytes};state<=INPUT;
                    end else if(rx_word==16'hf300 && configured)state<=START;
                    else error<=1;
                end
                CONFIG: if(rx_valid)begin
                    case(config_index)
                        0:program_base[15:0]<=rx_word;
                        1:begin program_base[23:16]<=rx_word[7:0];if(rx_word[15:8]!=0)error<=1;end
                        2:program_words<=rx_word;
                        3:begin input_base<=rx_word[9:0];if(rx_word[15:10]!=0)error<=1;end
                        4:begin input_bytes<=rx_word[10:0];if(rx_word[15:11]!=0)error<=1;state<=CHECK;end
                        default:error<=1;
                    endcase
                    config_index<=config_index+1'b1;
                end
                CHECK: begin
                    if(program_base[0] || program_base[23] || program_words==0 || program_end>25'h0800000 ||
                        input_base[0] || input_bytes>1024 || input_end>1024)error<=1;
                    else configured<=1;
                    state<=IDLE;
                end
                INPUT: if(rx_valid)state<=WRITE;
                WRITE: if(mem_ready)state<=WRITE_WAIT;
                WRITE_WAIT: if(mem_ready)begin
                    if(words_left<=2)state<=START;
                    else begin words_left<=words_left-2;pc<=pc+2;state<=INPUT;end
                end
                START: if(units_idle)begin pc<=program_base;words_left<=program_words;state<=FETCH;end
                FETCH: if(fetch_ready)state<=FETCH_WAIT;
                FETCH_WAIT: begin
                    if(fetch_byte_valid)begin
                        instruction_buffer<={instruction_buffer[55:0],fetch_data};
                    end
                    if(fetch_done)begin
                        buffered_words<=words_left>=4 ? 3'd4 : words_left[2:0];state<=ISSUE;
                    end
                end
                ISSUE: if(inst_ready)begin
                    pc<=pc+2;
                    words_left<=words_left-1'b1;buffered_words<=buffered_words-1'b1;
                    if(words_left==1)state<=DRAIN;
                    else if(buffered_words==1)state<=FETCH;
                end
                DRAIN: if(units_idle)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
