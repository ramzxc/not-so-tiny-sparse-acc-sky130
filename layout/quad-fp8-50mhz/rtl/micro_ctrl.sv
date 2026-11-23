// Keep a WB weight block resident while processing independent batch lanes.
module micro_ctrl (
    input wire clk, rst_n, sync, frame_ready, tx_idle,
    input wire [2:0] batch_size,
    input wire [3:0] complete_frames,
    input wire [2:0] frame_slot,
    input wire [8:0] available_bytes,
    input wire full,
    output logic [63:0] inst_word,
    output wire inst_enable, direct_wb,
    output wire fetch_req, fetch_take, fetch_pair,
    output logic [22:0] fetch_addr,
    input wire [63:0] fetched_word,
    input wire fetch_valid
);
    import tpu_pkg::*;

    localparam logic [22:0] PROGRAM_BASE = 23'h200000;
    localparam logic [22:0] TABLE_BASE = 23'h1ff000;
    localparam logic [22:0] INPUT_BASE = 23'h008000;
    localparam logic [22:0] STATE_BASE = 23'h003000;
    localparam logic [16:0] TABLE_END = 17'h1ffff;

    typedef enum logic [3:0] {WAIT_BATCH, TABLE_META, TABLE_WEIGHT, PROGRAM, SCAN,
                             LOAD_INPUT, NEXT_INPUT, LOAD_WB, SELECT_INPUT, MAC,
                             NEXT_COLUMN, WAIT_SYNC} state_t;
    state_t state;
    logic [2:0] head;
    logic [1:0] sample, output_lane;
    logic [2:0] samples;
    logic [16:0] pc, trigger_pc;
    logic [8:0] table_index, column, columns_left;
    logic [22:0] weight_addr;
    logic [2:0] row_shift;
    logic [3:0] active_samples;
    logic probe_valid;
    logic [9:0] probe_group;
    logic [1:0] nonzero;

    wire metadata_read = state==TABLE_META || state==TABLE_WEIGHT;
    wire reach_repeat = trigger_pc!=TABLE_END && pc==trigger_pc;
    wire raw_instruction = state==PROGRAM && !reach_repeat;
    wire column_ready = samples!=1 || column[8] || {1'b0,column[7:0]} < available_bytes;
    wire [9:0] current_group = {sample,column[8:1]};
    wire need_probe = state==SCAN && !(probe_valid && probe_group==current_group);
    wire [2:0] input_slot = head+3'(sample);
    wire [22:0] input_base = INPUT_BASE + {12'b0,input_slot,8'b0};
    wire [22:0] y_base = STATE_BASE + {13'b0,sample,8'b0};
    wire [22:0] scalar_addr = (column[8] ? y_base : input_base) + {15'b0,column[7:0]};
    wire [23:0] scalar_alias = 24'hc00000 + {1'b0,scalar_addr[19:0],3'b0};
    wire [7:0] rows = 8'd1 << row_shift;
    wire [22:0] weight_stride = row_shift<1 ? 23'd8 : 23'(rows)*4;
    wire [7:0] acc_addr = 8'(sample)<<row_shift;
    wire queued_sync = raw_instruction && fetched_word[7:0]==OPCODE_SYNCHRONIZE;
    wire can_emit_raw = raw_instruction && fetch_valid && (!queued_sync || tx_idle);
    wire emit = state==LOAD_INPUT || state==LOAD_WB || state==MAC ||
                (state==SELECT_INPUT && active_samples[sample]);

    assign fetch_req = metadata_read || (need_probe && column_ready) ||
                       (raw_instruction && !full);
    assign fetch_take = fetch_req && fetch_valid && (!queued_sync || tx_idle);
    assign fetch_pair = need_probe;
    assign inst_enable = !full && (emit || can_emit_raw);
    // Internal FIFO qualifier for the VPU SRAM request. It is not encoded
    // in the PSRAM instruction stream.
    assign direct_wb = state==MAC;

    always_comb begin
        if (metadata_read) fetch_addr = TABLE_BASE + {11'b0,table_index,3'b0};
        else if (need_probe) fetch_addr = {scalar_addr[22:1],1'b0};
        else fetch_addr = PROGRAM_BASE + {3'b0,pc,3'b0};

        inst_word = fetched_word;
        case (state)
            LOAD_INPUT: inst_word = {8'b0,scalar_alias,14'b0,sample,8'd1,OPCODE_DRAM_TO_BUFFER};
            LOAD_WB: inst_word = {9'b0,weight_addr,16'b0,rows,OPCODE_DRAM_TO_WEIGHT};
            SELECT_INPUT: inst_word = {53'b0,sample,1'b1,OPCODE_WEIGHT};
            MAC: inst_word = {40'b0,acc_addr,rows,(OPCODE_VPU_VEC_MUL | 8'h01)};
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= WAIT_BATCH;
            head <= 0;
            sample <= 0;
            output_lane <= 0;
            samples <= 0;
            pc <= 0;
            trigger_pc <= TABLE_END;
            table_index <= 0;
            column <= 0;
            columns_left <= 0;
            weight_addr <= 0;
            row_shift <= 0;
            active_samples <= 0;
            probe_valid <= 0;
            probe_group <= 0;
            nonzero <= 0;
        end else begin
            case (state)
                WAIT_BATCH: if ((batch_size==1 && frame_ready) ||
                                (batch_size>1 && complete_frames>={1'b0,batch_size})) begin
                    head <= frame_slot;
                    samples <= batch_size;
                    output_lane <= 0;
                    pc <= 0;
                    table_index <= 0;
                    probe_valid <= 0;
                    state <= TABLE_META;
                end
                TABLE_META: if (fetch_take) begin
                    trigger_pc <= fetched_word[16:0];
                    column <= fetched_word[25:17];
                    columns_left <= fetched_word[34:26];
                    row_shift <= fetched_word[37:35];
                    table_index <= table_index + 1'b1;
                    state <= fetched_word[16:0]==TABLE_END ? PROGRAM : TABLE_WEIGHT;
                end
                TABLE_WEIGHT: if (fetch_take) begin
                    weight_addr <= fetched_word[22:0];
                    table_index <= table_index + 1'b1;
                    state <= PROGRAM;
                end
                PROGRAM: begin
                    if (reach_repeat) begin
                        sample <= 0;
                        active_samples <= 0;
                        state <= SCAN;
                    end else if (fetch_take) begin
                        pc <= pc + 1'b1;
                        if (queued_sync) state <= WAIT_SYNC;
                    end
                end
                SCAN: if (column_ready) begin
                    if (fetch_take && need_probe) begin
                        probe_valid <= 1;
                        probe_group <= current_group;
                        nonzero <= {|fetched_word[14:8], |fetched_word[6:0]};
                    end else if (!need_probe) begin
                        active_samples[sample] <= nonzero[column[0]];
                        state <= nonzero[column[0]] ? LOAD_INPUT : NEXT_INPUT;
                    end
                end
                LOAD_INPUT: if (inst_enable) state <= NEXT_INPUT;
                NEXT_INPUT: begin
                    if (3'(sample)+1'b1 == samples) begin
                        state <= active_samples!=0 ? LOAD_WB : NEXT_COLUMN;
                    end else begin
                        sample <= sample + 1'b1;
                        state <= SCAN;
                    end
                end
                LOAD_WB: if (inst_enable) begin
                    sample <= 0;
                    state <= SELECT_INPUT;
                end
                SELECT_INPUT: begin
                    if (inst_enable) state <= MAC;
                    else if (!active_samples[sample]) begin
                        if (3'(sample)+1'b1==samples) state <= NEXT_COLUMN;
                        else sample <= sample+1'b1;
                    end
                end
                MAC: if (inst_enable) begin
                    if (3'(sample)+1'b1==samples) state <= NEXT_COLUMN;
                    else begin
                        sample <= sample+1'b1;
                        state <= SELECT_INPUT;
                    end
                end
                NEXT_COLUMN: begin
                    column <= column + 1'b1;
                    columns_left <= columns_left - 1'b1;
                    weight_addr <= weight_addr + weight_stride;
                    active_samples <= 0;
                    sample <= 0;
                    state <= columns_left==1 ? TABLE_META : SCAN;
                end
                WAIT_SYNC: if (sync) begin
                    output_lane <= output_lane + 1'b1;
                    state <= 3'(output_lane)+1'b1 == samples ? WAIT_BATCH : PROGRAM;
                end
                default: state <= WAIT_BATCH;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n) begin
        if (inst_enable && (inst_word[7:0]==8'hfd || inst_word[7:0]==8'hfe || inst_word[7:0]==8'h0a))
            $fatal(1,"Unexpected opcode");
        if (fetch_take && state==TABLE_META && fetched_word[16:0]!=TABLE_END &&
            (fetched_word[34:26]==0 || fetched_word[16:0]<pc || fetched_word[37:35]>5 ||
             ((32'd1<<fetched_word[37:35])*32'(samples)>32)))
            $fatal(1,"Invalid repeat descriptor");
        if (fetch_take && state==TABLE_WEIGHT && (fetched_word[63:21]!=0 || fetched_word[2:0]!=0))
            $fatal(1,"Invalid WB address");
    end
`endif
endmodule
