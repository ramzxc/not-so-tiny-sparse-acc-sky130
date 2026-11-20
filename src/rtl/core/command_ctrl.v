// Program fetch and generic MICRO sequencing form one command-control block.
// Internal FSMs remain separate; merging their state would change scheduling.
module command_ctrl (
    input wire clk,rst_n,
    input wire [15:0] frontend_rx_word,
    input wire frontend_rx_valid,
    output wire frontend_ready,host_error,host_busy,micro_error,micro_busy,
    input wire units_idle,bus_busy,memory_error,uart_error,
    input wire [23:0] addr,
    input wire [1:0] loaded_input_zero_mask,
    output wire [15:0] sequenced_inst,
    output wire sequenced_valid,
    input wire sequenced_ready,
    output wire fetch_valid,
    output wire [22:0] fetch_addr,
    output wire [3:0] fetch_bytes,
    input wire fetch_ready,fetch_done,fetch_byte_valid,
    input wire [7:0] qspi_read_data,
    output wire input_write,
    output wire [9:0] input_addr,
    output wire [15:0] input_data,
    input wire mem_rdy
);
    wire [15:0] inst;
    wire inst_val,decoder_rdy;
    program_fetch frontend (
        .clk(clk),.rst_n(rst_n),.rx_word(frontend_rx_word),.rx_valid(frontend_rx_valid),
        .rx_ready(frontend_ready),.error(host_error),.busy(host_busy),
        .units_idle(units_idle && !micro_busy && !bus_busy),
        .memory_error(memory_error | micro_error | uart_error),
        .inst(inst),.inst_valid(inst_val),.inst_ready(decoder_rdy),
        .fetch_valid(fetch_valid),.fetch_addr(fetch_addr),.fetch_bytes(fetch_bytes),
        .fetch_ready(fetch_ready),.fetch_done(fetch_done),.fetch_data(qspi_read_data),
        .fetch_byte_valid(fetch_byte_valid),
        .input_write(input_write),.input_addr(input_addr),.input_data(input_data),.mem_ready(mem_rdy)
    );
    micro_ctrl sequencer (
        .clk(clk), .rst_n(rst_n), .host_inst(inst), .host_valid(inst_val),
        .host_ready(decoder_rdy), .core_inst(sequenced_inst), .core_valid(sequenced_valid),
        .core_ready(sequenced_ready), .units_idle(units_idle),
        .staging_addr(addr), .input_zero_mask(loaded_input_zero_mask),
        .memory_error(memory_error), .busy(micro_busy), .error(micro_error)
    );
endmodule

// Private fetch controller.
// UART words configure a replayable PSRAM program and supply raw input frames.
// 8N1, low byte first, one 01h READY credit per word. Commands are not UART data.
// F100 + base_lo16 + base_hi8 + word_count + SRAM_input_base + input_byte_count.
// F200 + ceil(input_byte_count/2) payload words: commit input then run program.
// F300: run the configured program without changing SRAM input.
// No branches/loops here: MICRO still performs its existing generic operations.
module program_fetch (
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

// Private generic instruction sequencer.
`include "defs/defs.vh"
`include "defs/inst_defs.vh"

// Fixed column-wise instruction sequencer. No instruction RAM or arithmetic unit.
// Reuses DATA/MEM/EXEC/SYNC and mem_itf's FP8 SRAM accumulation.
// Optional weight tiling emits ordinary DMA commands through the same
// dispatch path. No EGRU-specific dimensions, gates, or state are encoded here.
module micro_ctrl (
    input wire clk, rst_n,
    input wire [15:0] host_inst,
    input wire host_valid,
    output wire host_ready,
    output reg [15:0] core_inst,
    output wire core_valid,
    input wire core_ready, units_idle,
    input wire [23:0] staging_addr,
    input wire [1:0] input_zero_mask,
    input wire memory_error,
    output wire busy,
    output reg error
);
    localparam [4:0] IDLE=0, I_DATA=1, I_LO=2, I_HI=3, I_MEM=4, I_SYNC=5,
        COLUMN_CHECK=6, W_DATA=7, W_LO=8, W_HI=9, W_MEM=10, W_SYNC=11,
        EXEC=12, EXEC_SYNC=13, STORE=14, A_LO=15, A_HI=16, A_MEM=17,
        A_SYNC=18, COLUMN_END=19, B_NEXT=20, B_VALIDATE=21,
        D_SRC_LO=22, D_SRC_HI=23, D_SOURCE=24, D_DST_LO=25, D_DST_HI=26,
        D_DEST=27, D_RUN=28, D_WAIT=29, D_NEXT=30, D_VALIDATE_INPUT=31;
    reg [4:0] state;
    // Input/weight pointers and column count are consumed in place to save flops.
    reg [23:0] input_addr, weight_addr;
    reg input_sram, weight_sram;
    reg [9:0] acc_base, acc_addr;
    reg [7:0] groups, groups_left, columns_left;
    reg cur, sparse;
    reg [7:0] batch_size, batch_left;
    reg [23:0] batch_addr;
    reg [10:0] checked_end;
    reg dma_mode, scan_for_dma;
    reg [9:0] buffer_base, buffer_addr;
    reg [23:0] column_stride;
    reg [10:0] tile_input_end;
    wire [23:0] read_weight_addr = dma_mode ? {14'b0,buffer_addr} : weight_addr;
    wire batched = batch_size != 1;
    wire compact_sram=dma_mode && input_sram;
    wire [3:0] compact_weight_kind=batched ? 4'd1 : 4'd6+{2'b0,sparse,cur};
    wire [23:0] read_input_addr = batched ? batch_addr : input_addr;
    wire is_micro = host_inst[15:13] == `OPCODE_MICRO;
    wire command_state = state != COLUMN_CHECK && state != COLUMN_END &&
                         state != B_NEXT && state != B_VALIDATE && state != D_NEXT &&
                         state != D_VALIDATE_INPUT;
    wire fire = core_valid && core_ready;
    // One shared pointer incrementer. A skipped column advances all its weights.
    wire advance_weight = dma_mode ? state == D_NEXT : batched ? state == B_NEXT :
                          (state == A_SYNC || state == COLUMN_CHECK);
    wire advance_buffer = dma_mode && (state == B_NEXT || (!batched && state == A_SYNC));
    wire advance_batch = batched && (state == A_SYNC || (scan_for_dma && state == COLUMN_CHECK));
    wire [23:0] pointer = advance_weight ? weight_addr :
                          (advance_buffer ? {14'b0,buffer_addr} :
                          (advance_batch ? batch_addr : input_addr));
    wire [23:0] step_bytes = (dma_mode && state == D_NEXT) ?
                             (column_stride != 0 ? column_stride : {15'b0,groups,1'b0}) :
                             ((batched && state == COLUMN_END) ? {15'b0,batch_size,1'b0} :
                             ((!batched && state == COLUMN_CHECK) ? {15'b0,groups,1'b0} : 24'd2));
    wire [24:0] pointer_sum = {1'b0,pointer} + {1'b0,step_bytes};
    wire [23:0] next_pointer = pointer_sum[24] ? 24'hffffff : pointer_sum[23:0];
    wire [10:0] acc_end = {1'b0,acc_base} + {2'b0,groups,1'b0};
    wire [10:0] buffer_end = {1'b0,buffer_base} + {2'b0,groups,1'b0};
    // Validate packed spans by repeated addition, without a groups*batch multiplier.
    wire [10:0] checked_next = checked_end + {2'b0,batch_size,1'b0};
    wire tile_invalid = weight_sram || buffer_end > 1024 ||
        (input_sram && (input_addr >= 1024 || input_addr[0] != 0));
    wire output_overlap = ({1'b0,acc_base} < buffer_end && {1'b0,buffer_base} < checked_next) ||
        (input_sram && ({1'b0,acc_base} < tile_input_end &&
                       {1'b0,input_addr[9:0]} < checked_next));
    assign busy = state != IDLE;
    assign host_ready = rst_n && !busy && (is_micro ? units_idle : core_ready);
    assign core_valid = rst_n && (busy ? (command_state && !memory_error && (state!=STORE || units_idle)) :
                                                (host_valid && !is_micro));
    always @(*) begin
        core_inst = host_inst;
        if (busy) begin
            case (state)
                I_DATA: core_inst = compact_sram ?
                    {3'b111,(batched ? (4'd2+{2'b0,sparse,cur}) : 4'd0),read_input_addr[9:1]} :
                    batched ? (16'h8100 | {4'b0,sparse,1'b0,cur,9'b0}) : 16'h8000; // input pair, vector mode
                I_LO: core_inst = {4'h2,read_input_addr[11:0]};
                I_HI: core_inst = {4'h3,read_input_addr[23:12]};
                I_MEM: core_inst = 16'h4000 | {5'b0,input_sram,10'b0};
                I_SYNC, W_SYNC, EXEC_SYNC, A_SYNC, D_WAIT: core_inst = 16'hffff;
                W_DATA: core_inst = compact_sram ? {3'b111,compact_weight_kind,buffer_addr[9:1]} :
                    (batched ? 16'h8400 : (16'h8500 | {4'b0,sparse,1'b0,cur,9'b0}));
                W_LO: core_inst = {4'h2,read_weight_addr[11:0]};
                W_HI: core_inst = {4'h3,read_weight_addr[23:12]};
                W_MEM: core_inst = 16'h4000 | {5'b0,(weight_sram | dma_mode),10'b0};
                EXEC: core_inst = 16'h6800; // MUL overwrite, no activation
                STORE: core_inst = compact_sram ? {3'b111,4'd11,acc_addr[9:1]} : 16'h9000;
                A_LO: core_inst = {4'h2,2'b0,acc_addr};
                A_HI: core_inst = 16'h3000;
                A_MEM: core_inst = 16'h5600; // SRAM read-add-write
                D_SRC_LO: core_inst = {4'h2,weight_addr[11:0]};
                D_SRC_HI: core_inst = {4'h3,weight_addr[23:12]};
                D_SOURCE: core_inst = `INST_DMA_SOURCE;
                D_DST_LO: core_inst = {4'h2,2'b0,buffer_base};
                D_DST_HI: core_inst = 16'h3000;
                D_DEST: core_inst = `INST_DMA_DEST;
                D_RUN: core_inst = `INST_DMA_RUN(groups);
                default: core_inst = 16'h0000;
            endcase
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; error <= 0;
            input_addr <= 0; weight_addr <= 0; acc_base <= 0; acc_addr <= 0;
            input_sram <= 0; weight_sram <= 0;
            groups <= 0; groups_left <= 0; columns_left <= 0;
            cur <= 0; sparse <= 0;
            batch_size <= 1; batch_left <= 0; batch_addr <= 0; checked_end <= 0;
            dma_mode <= 0; scan_for_dma <= 0;
            buffer_base <= 0; buffer_addr <= 0; column_stride <= 0; tile_input_end <= 0;
        end else if (busy && memory_error) begin
            // Stop issuing instructions, drain an accepted operation, then release host.
            error <= 1;
            if (units_idle) state <= IDLE;
        end else if (!busy) begin
            if (host_valid && host_ready && is_micro) begin
                case (host_inst[12:10])
                    `MICRO_INPUT: begin
                        if (host_inst[9:1] != 0) error <= 1;
                        else begin input_addr <= staging_addr; input_sram <= host_inst[0]; end
                    end
                    `MICRO_WEIGHT: begin
                        if (host_inst[9:1] != 0) error <= 1;
                        else begin weight_addr <= staging_addr; weight_sram <= host_inst[0]; end
                    end
                    `MICRO_ACC: begin
                        if (host_inst[9:0] != 0 || staging_addr > 1022 || staging_addr[0] != 0)
                            error <= 1;
                        else acc_base <= staging_addr[9:0];
                    end
                    `MICRO_GROUPS: begin
                        if (host_inst[9:8] != 0) error <= 1;
                        else groups <= host_inst[7:0];
                    end
                    `MICRO_COLUMNS: begin
                        if (host_inst[9:8] != 0) error <= 1;
                        else columns_left <= host_inst[7:0];
                    end
                    `MICRO_BATCH: begin
                        if (host_inst[9:8] != 0 || host_inst[7:0] == 0 || host_inst[7:0] > 128)
                            error <= 1;
                        else batch_size <= host_inst[7:0];
                    end
                    `MICRO_TILE: begin
                        if (host_inst[9:1] != 0) error <= 1;
                        else if (host_inst[0]) column_stride <= staging_addr;
                        else if (staging_addr > 1022 || staging_addr[0] != 0) error <= 1;
                        else buffer_base <= staging_addr[9:0];
                    end
                    `MICRO_RUN: begin
                        if (host_inst[9:2] != 0 || error || memory_error) error <= 1;
                        else if (groups != 0 && columns_left != 0) begin
                            if (acc_end > 1024 || (host_inst[1] && tile_invalid)) error <= 1;
                            else begin
                                cur <= 0; sparse <= host_inst[0]; dma_mode <= host_inst[1];
                                scan_for_dma <= 0;
                                if (host_inst[1] && input_sram) begin
                                    checked_end <= {1'b0,input_addr[9:0]};
                                    groups_left <= {1'b0,columns_left[7:1]} + {7'b0,columns_left[0]};
                                    state <= D_VALIDATE_INPUT;
                                end else if (batched || host_inst[1]) begin
                                    checked_end <= {1'b0,acc_base};
                                    groups_left <= groups;
                                    state <= B_VALIDATE;
                                end else state <= I_DATA;
                            end
                        end
                    end
                    default: error <= 1;
                endcase
            end
        end else begin
            case (state)
                I_DATA: if (fire) state <= compact_sram ? I_SYNC : I_LO;
                I_LO: if (fire) state <= I_HI;
                I_HI: if (fire) state <= I_MEM;
                I_MEM: if (fire) state <= I_SYNC;
                I_SYNC: if (fire) state <= COLUMN_CHECK;
                D_VALIDATE_INPUT: begin
                    if (checked_next > 1024 ||
                        ({1'b0,input_addr[9:0]} < buffer_end && {1'b0,buffer_base} < checked_next)) begin
                        error <= 1; state <= IDLE;
                    end else if (groups_left == 1) begin
                        tile_input_end <= checked_next[10:0];
                        checked_end <= {1'b0,acc_base}; groups_left <= groups;
                        state <= B_VALIDATE;
                    end else begin
                        checked_end <= checked_next; groups_left <= groups_left - 1'b1;
                    end
                end
                B_VALIDATE: begin
                    // Repeated addition avoids a groups * batch multiplier.
                    if (checked_next > 1024 || (dma_mode && output_overlap)) begin
                        error <= 1; state <= IDLE;
                    end else begin
                        checked_end <= checked_next;
                        if (groups_left == 1) begin
                            groups_left <= groups; acc_addr <= acc_base;
                            batch_left <= batch_size; batch_addr <= input_addr;
                            scan_for_dma <= dma_mode && batched;
                            state <= dma_mode ? I_DATA : W_DATA;
                        end else groups_left <= groups_left - 1'b1;
                    end
                end
                COLUMN_CHECK: begin
                    if (scan_for_dma) begin
                        // Search until the first nonzero sample. No per-batch mask
                        // buffer is needed; compute rereads the packed input pairs.
                        if (!sparse || !input_zero_mask[cur]) begin
                            scan_for_dma <= 0;
                            groups_left <= groups; acc_addr <= acc_base;
                            buffer_addr <= buffer_base; state <= D_SRC_LO;
                        end else if (batch_left == 1) begin
                            scan_for_dma <= 0; state <= D_NEXT;
                        end else begin
                            batch_left <= batch_left - 1'b1;
                            batch_addr <= next_pointer; state <= I_DATA;
                        end
                    end else if (batched) begin
                        if (sparse && input_zero_mask[cur]) state <= A_SYNC;
                        else state <= EXEC;
                    end else if (sparse && input_zero_mask[cur]) begin
                        if (dma_mode) state <= D_NEXT;
                        else begin weight_addr <= next_pointer; state <= COLUMN_END; end
                    end else begin
                        groups_left <= groups; acc_addr <= acc_base;
                        if (dma_mode) begin
                            buffer_addr <= buffer_base; state <= D_SRC_LO;
                        end else state <= W_DATA;
                    end
                end
                D_SRC_LO: if (fire) state <= D_SRC_HI;
                D_SRC_HI: if (fire) state <= D_SOURCE;
                D_SOURCE: if (fire) state <= D_DST_LO;
                D_DST_LO: if (fire) state <= D_DST_HI;
                D_DST_HI: if (fire) state <= D_DEST;
                D_DEST: if (fire) state <= D_RUN;
                D_RUN: if (fire) state <= D_WAIT;
                D_WAIT: if (fire) begin
                    batch_addr <= input_addr; batch_left <= batch_size;
                    state <= W_DATA;
                end
                D_NEXT: begin weight_addr <= next_pointer; state <= COLUMN_END; end
                W_DATA: if (fire) state <= compact_sram ? W_SYNC : W_LO;
                W_LO: if (fire) state <= dma_mode && input_sram ? W_MEM : W_HI;
                W_HI: if (fire) state <= W_MEM;
                W_MEM: if (fire) state <= W_SYNC;
                W_SYNC: if (fire) state <= batched ? I_DATA : EXEC;
                // STORE waits for idle units itself, including the newest EXEC result.
                EXEC: if (fire) state <= STORE;
                EXEC_SYNC: if (fire) state <= STORE;
                STORE: if (fire) state <= compact_sram ? A_SYNC : A_LO;
                A_LO: if (fire) state <= dma_mode && input_sram ? A_MEM : A_HI;
                A_HI: if (fire) state <= A_MEM;
                A_MEM: if (fire) state <= A_SYNC;
                A_SYNC: if (fire) begin
                    if (batched) begin
                        acc_addr <= acc_addr + 10'd2;
                        if (batch_left == 1) state <= B_NEXT;
                        else begin
                            batch_left <= batch_left - 1'b1;
                            batch_addr <= next_pointer;
                            state <= I_DATA;
                        end
                    end else begin
                        if (dma_mode) begin
                            if (groups_left != 1) buffer_addr <= next_pointer[9:0];
                        end else weight_addr <= next_pointer;
                        if (groups_left == 1) state <= dma_mode ? D_NEXT : COLUMN_END;
                        else begin
                            groups_left <= groups_left - 1'b1;
                            acc_addr <= acc_addr + 10'd2;
                            state <= W_DATA;
                        end
                    end
                end
                B_NEXT: begin
                    if (!dma_mode) weight_addr <= next_pointer;
                    else if (groups_left != 1) buffer_addr <= next_pointer[9:0];
                    if (groups_left == 1) state <= dma_mode ? D_NEXT : COLUMN_END;
                    else begin
                        groups_left <= groups_left - 1'b1;
                        batch_left <= batch_size; batch_addr <= input_addr;
                        state <= W_DATA;
                    end
                end
                COLUMN_END: begin
                    if (cur || columns_left == 1) input_addr <= next_pointer;
                    if (columns_left == 1) begin
                        columns_left <= 0; state <= IDLE;
                    end else begin
                        columns_left <= columns_left - 1'b1;
                        cur <= !cur;
                        if (batched) begin
                            groups_left <= groups; acc_addr <= acc_base;
                            batch_left <= batch_size;
                            batch_addr <= cur ? next_pointer : input_addr;
                            scan_for_dma <= dma_mode;
                            state <= dma_mode ? I_DATA : W_DATA;
                        end else state <= cur ? I_DATA : COLUMN_CHECK;
                    end
                end
                default: begin error <= 1; state <= IDLE; end
            endcase
        end
    end
endmodule
