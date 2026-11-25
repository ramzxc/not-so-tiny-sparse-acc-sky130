`include "../defs/defs.vh"
`include "../defs/inst_defs.vh"

// Fixed column-wise instruction sequencer. No instruction RAM or arithmetic unit.
// Reuses DATA/MEM/EXEC/SYNC and mem_itf's FP16 SRAM accumulation.
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
        A_SYNC=18, COLUMN_END=19, B_NEXT=20, B_VALIDATE=21;
    reg [4:0] state;
    // Input/weight pointers and column count are consumed in place to save flops.
    reg [23:0] input_addr, weight_addr;
    reg input_sram, weight_sram;
    reg [8:0] acc_base, acc_addr;
    reg [7:0] groups, groups_left, columns_left;
    reg cur, sparse;
    reg [7:0] batch_size, batch_left;
    reg [23:0] batch_addr;
    reg [10:0] checked_end;
    wire batched = batch_size != 1;
    wire [23:0] read_input_addr = batched ? batch_addr : input_addr;
    wire is_micro = host_inst[15:13] == `OPCODE_MICRO;
    wire command_state = state != COLUMN_CHECK && state != COLUMN_END &&
                         state != B_NEXT && state != B_VALIDATE;
    wire fire = core_valid && core_ready;
    // One shared pointer incrementer. A skipped column advances all its weights.
    wire advance_weight = batched ? state == B_NEXT :
                          (state == A_SYNC || state == COLUMN_CHECK);
    wire [23:0] pointer = advance_weight ? weight_addr :
                          ((batched && state == A_SYNC) ? batch_addr : input_addr);
    wire [9:0] step_bytes = (batched && state == COLUMN_END) ? {batch_size,2'b00} :
                             ((!batched && state == COLUMN_CHECK) ? {groups,2'b00} : 10'd4);
    wire [24:0] pointer_sum = {1'b0,pointer} + {15'b0,step_bytes};
    wire [23:0] next_pointer = pointer_sum[24] ? 24'hffffff : pointer_sum[23:0];
    wire [10:0] acc_end = {2'b0,acc_base} + {1'b0,groups,2'b00};
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
                I_SYNC, W_SYNC, EXEC_SYNC, A_SYNC: core_inst = 16'hffff;
                W_DATA: core_inst = batched ? 16'h8400 : (16'h8500 | {4'b0,sparse,1'b0,cur,9'b0});
                W_LO: core_inst = {4'h2,weight_addr[11:0]};
                W_HI: core_inst = {4'h3,weight_addr[23:12]};
                W_MEM: core_inst = 16'h4000 | {5'b0,weight_sram,10'b0};
                EXEC: core_inst = 16'h6800; // MUL overwrite, no activation
                STORE: core_inst = 16'h9000;
                A_LO: core_inst = {4'h2,3'b0,acc_addr};
                A_HI: core_inst = 16'h3000;
                A_MEM: core_inst = 16'h5600; // SRAM read-add-write
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
                        if (host_inst[9:0] != 0 || staging_addr > 508 || staging_addr[1:0] != 0)
                            error <= 1;
                        else acc_base <= staging_addr[8:0];
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
                    `MICRO_RUN: begin
                        if (host_inst[9:1] != 0 || error || memory_error) error <= 1;
                        else if (groups != 0 && columns_left != 0) begin
                            if (acc_end > 512) error <= 1;
                            else begin
                                cur <= 0; sparse <= host_inst[0];
                                if (batched) begin
                                    checked_end <= {2'b0,acc_base};
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
                B_VALIDATE: begin
                    // Repeated addition avoids a groups * batch multiplier.
                    if (checked_end + {1'b0,batch_size,2'b00} > 512) begin
                        error <= 1; state <= IDLE;
                    end else begin
                        checked_end <= checked_end + {1'b0,batch_size,2'b00};
                        if (groups_left == 1) begin
                            groups_left <= groups; acc_addr <= acc_base;
                            batch_left <= batch_size; batch_addr <= input_addr;
                            state <= W_DATA;
                        end else groups_left <= groups_left - 1'b1;
                    end
                end
                COLUMN_CHECK: begin
                    if (batched) begin
                        if (sparse && input_zero_mask[cur]) state <= A_SYNC;
                        else state <= EXEC;
                    end else if (sparse && input_zero_mask[cur]) begin
                        weight_addr <= next_pointer;
                        state <= COLUMN_END;
                    end else begin
                        groups_left <= groups; acc_addr <= acc_base;
                        state <= W_DATA;
                    end
                end
                W_DATA: if (fire) state <= W_LO;
                W_LO: if (fire) state <= W_HI;
                W_HI: if (fire) state <= W_MEM;
                W_MEM: if (fire) state <= W_SYNC;
                W_SYNC: if (fire) state <= batched ? I_DATA : EXEC;
                EXEC: if (fire) state <= EXEC_SYNC;
                EXEC_SYNC: if (fire) state <= STORE;
                STORE: if (fire) state <= A_LO;
                A_LO: if (fire) state <= A_HI;
                A_HI: if (fire) state <= A_MEM;
                A_MEM: if (fire) state <= A_SYNC;
                A_SYNC: if (fire) begin
                    if (batched) begin
                        acc_addr <= acc_addr + 9'd4;
                        if (batch_left == 1) state <= B_NEXT;
                        else begin
                            batch_left <= batch_left - 1'b1;
                            batch_addr <= next_pointer;
                            state <= I_DATA;
                        end
                    end else begin
                        weight_addr <= next_pointer;
                        if (groups_left == 1) state <= COLUMN_END;
                        else begin
                            groups_left <= groups_left - 1'b1;
                            acc_addr <= acc_addr + 9'd4;
                            state <= W_DATA;
                        end
                    end
                end
                B_NEXT: begin
                    weight_addr <= next_pointer;
                    if (groups_left == 1) state <= COLUMN_END;
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
                            state <= W_DATA;
                        end else state <= cur ? I_DATA : COLUMN_CHECK;
                    end
                end
                default: begin error <= 1; state <= IDLE; end
            endcase
        end
    end
endmodule
