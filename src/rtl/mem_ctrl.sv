// Shared WB/UB/ACC controller. Logical addresses are 32-bit row indices.
// Region 0=UB, 1=ACC, 2=WB. Each physical word holds two logical rows.
// Round-robin arbitration; two shared tagged response slots. Writes are atomic
// read-modify-write transactions because the macro has no byte write mask.
module mem_ctrl
    import tpu_pkg::*;
#(
    parameter int SRAM_BYTES = DEFAULT_SRAM_BYTES,
    parameter int CLIENTS = 12,
    parameter int UB_ROWS = SRAM_BYTES / 8,
    parameter int ACC_ROWS = SRAM_BYTES / 16,
    parameter int WB_ROWS = SRAM_BYTES / 16,
    parameter int AW = $clog2(SRAM_BYTES / 8),
    parameter int CW = $clog2(CLIENTS)
)(
    input logic clk, rst,
    input logic [CLIENTS-1:0] req_valid, req_write, req_accumulate,
    input logic [CLIENTS-1:0][1:0] req_region,
    input logic [CLIENTS-1:0][23:0] req_addr,
    input logic [CLIENTS-1:0][31:0] req_data,
    output logic [CLIENTS-1:0] req_ready,
    output logic [CLIENTS-1:0] rsp_valid,
    output logic [CLIENTS-1:0][31:0] rsp_data,
    input logic [CLIENTS-1:0] rsp_ready,
    output logic busy, error
);
    typedef enum logic [1:0] {IDLE, READ_RESULT, ACC_UPPER, WRITE_COMMIT} state_t;
    state_t state;
    logic [CW-1:0] next_client, selected;
    logic selected_valid, address_ok;
    logic [AW-1:0] mapped_addr, saved_addr;
    logic selected_half, saved_half, saved_write, saved_accumulate;
    logic [31:0] saved_data, old_row;
    logic [63:0] write_word, macro_data;
    logic macro_enable, macro_write;
    logic [AW-1:0] macro_addr;
    logic [CLIENTS-1:0] eligible, upper_eligible, grant;
    logic [AW:0] selected_row, row_limit, row_base;
    logic selected_address_high;
    logic [1:0] selected_region;
    logic [31:0] selected_data;
    logic selected_write, selected_accumulate;
    logic [15:0] add_a, add_b, add_result;

    logic [1:0] slot_valid;
    logic [1:0][CW-1:0] slot_owner;
    logic [1:0][31:0] slot_data;
    logic free_slot, saved_slot, slot_available;
    assign slot_available = !(&slot_valid);
    assign free_slot = slot_valid[0];

    // Independent slots: a stalled response does not block the other slot.
    always_comb begin
        rsp_valid = '0;
        rsp_data = '0;
        for (int i=0; i<CLIENTS; i++) begin
            for (int j=0; j<2; j++) begin
                if (slot_valid[j] && slot_owner[j] == CW'(i)) begin
                    rsp_valid[i] = 1;
                    rsp_data[i] = slot_data[j];
                end
            end
        end
    end

    always_comb begin
        // Full response slots block reads only. Writes can still make progress.
        eligible = req_valid & ~rsp_valid & (req_write | {CLIENTS{slot_available}});
        for (int i=0;i<CLIENTS;i++) upper_eligible[i] = eligible[i] && (CW'(i) >= next_client);
        grant = '0;
        selected = '0;
        selected_valid = 0;
        for (int i=0;i<CLIENTS;i++) begin
            if (!selected_valid && ((|upper_eligible) ? upper_eligible[i] : eligible[i])) begin
                grant[i] = 1;
                selected = CW'(i);
                selected_valid = 1;
            end
        end
        // Mux only the physical row bits. Keep a separate high-bit flag so
        // invalid architectural addresses never alias into a legal region.
        selected_row = '0;
        selected_address_high = 0;
        selected_region = '0;
        selected_data = '0;
        selected_write = 0;
        selected_accumulate = 0;
        for (int i=0;i<CLIENTS;i++) begin
            selected_row |= req_addr[i][AW:0] & {(AW+1){grant[i]}};
            selected_address_high |= grant[i] && (|req_addr[i][23:AW+1]);
            selected_region |= req_region[i] & {2{grant[i]}};
            selected_data |= req_data[i] & {32{grant[i]}};
            selected_write |= req_write[i] && grant[i];
            selected_accumulate |= req_accumulate[i] && grant[i];
        end
        row_limit = '0;
        row_base = '0;
        case (selected_region)
            0: begin row_limit = (AW+1)'(UB_ROWS); row_base = 0; end
            1: begin row_limit = (AW+1)'(ACC_ROWS); row_base = (AW+1)'(UB_ROWS); end
            2: begin row_limit = (AW+1)'(WB_ROWS); row_base = (AW+1)'(UB_ROWS+ACC_ROWS); end
            default: ;
        endcase
        address_ok = !selected_address_high && selected_row < row_limit;
        mapped_addr = AW'((row_base + selected_row) >> 1);
        selected_half = selected_row[0];
        req_ready = '0;
        if (!rst && state == IDLE) req_ready = grant;
    end

    assign busy = (state != IDLE) || (|req_valid) || (|rsp_valid);
    assign old_row = saved_half ? macro_data[63:32] : macro_data[31:0];
    assign add_a = state == ACC_UPPER ? write_word[(saved_half ? 48 : 16) +: 16] : old_row[15:0];
    assign add_b = state == ACC_UPPER ? saved_data[31:16] : saved_data[15:0];
    assign add_result = fp16_add(add_a,add_b);
    assign macro_enable = !rst && ((state == IDLE && selected_valid && address_ok) || state == WRITE_COMMIT);
    assign macro_write = (state == WRITE_COMMIT);
    assign macro_addr = (state == WRITE_COMMIT) ? saved_addr : mapped_addr;
    shared_sram #(.SRAM_BYTES(SRAM_BYTES)) memory (
        .clk(clk), .enable(macro_enable), .write(macro_write),
        .addr(macro_addr), .wdata(write_word), .rdata(macro_data)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            next_client <= '0;
            saved_slot <= 0;
            slot_valid <= '0;
            slot_owner <= '0;
            slot_data <= '0;
            saved_addr <= '0;
            saved_half <= 0;
            saved_write <= 0;
            saved_accumulate <= 0;
            saved_data <= '0;
            write_word <= '0;
            error <= 0;
        end else begin
            for (int j=0; j<2; j++)
                if (slot_valid[j] && rsp_ready[slot_owner[j]]) slot_valid[j] <= 0;
            case (state)
                IDLE: if (selected_valid) begin
                    next_client <= selected == CW'(CLIENTS-1) ? '0 : selected + 1'b1;
                    if (!selected_write) begin
                        saved_slot <= free_slot;
                        slot_owner[free_slot] <= selected;
                    end
                    if (!address_ok) begin
                        // Never truncate an out-of-range address into another region.
                        error <= 1;
                        if (!selected_write) begin
                            slot_valid[free_slot] <= 1;
                            slot_data[free_slot] <= '0;
                        end
                    end else begin
                        saved_addr <= mapped_addr;
                        saved_half <= selected_half;
                        saved_write <= selected_write;
                        saved_accumulate <= selected_accumulate;
                        saved_data <= selected_data;
                        state <= READ_RESULT;
                    end
                end
                READ_RESULT: begin
                    // Macro sampled at preceding posedge, returned data at negedge.
                    if (saved_write) begin
                        if (saved_accumulate) begin
                            write_word <= macro_data;
                            write_word[(saved_half ? 32 : 0) +: 16] <= add_result;
                            state <= ACC_UPPER;
                        end else begin
                            write_word <= saved_half ? {saved_data,macro_data[31:0]}
                                                     : {macro_data[63:32],saved_data};
                            state <= WRITE_COMMIT;
                        end
                    end else begin
                        slot_valid[saved_slot] <= 1;
                        slot_data[saved_slot] <= old_row;
                        state <= IDLE;
                    end
                end
                ACC_UPPER: begin
                    write_word[(saved_half ? 48 : 16) +: 16] <= add_result;
                    state <= WRITE_COMMIT;
                end
                WRITE_COMMIT: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (CLIENTS < 2) $fatal(1,"mem_ctrl requires at least two clients");
        if (UB_ROWS < 2 || ACC_ROWS < 2 || WB_ROWS < 2 ||
            (UB_ROWS % 2) || (ACC_ROWS % 2) || (WB_ROWS % 2) ||
            ((UB_ROWS+ACC_ROWS+WB_ROWS)*4 > SRAM_BYTES))
            $fatal(1,"Invalid or overlapping shared SRAM partition sizes");
    end
`endif
endmodule
