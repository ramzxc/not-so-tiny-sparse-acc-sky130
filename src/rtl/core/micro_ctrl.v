`include "../defs/defs.vh"
`include "../defs/inst_defs.vh"

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
    assign core_valid = rst_n && (busy ? (command_state && !memory_error) :
                                                (host_valid && !is_micro));
    always @(*) begin
        core_inst = host_inst;
        if (busy) begin
            case (state)
                I_DATA: core_inst = batched ? (16'h8100 | {4'b0,sparse,1'b0,cur,9'b0}) : 16'h8000; // input pair, vector mode
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
                I_DATA: if (fire) state <= I_LO;
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
                EXEC: if (fire) state <= EXEC_SYNC;
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
