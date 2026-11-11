// Shared WB/UB/ACC controller. Logical addresses are 32-bit row indices.
// Region 0=UB, 1=ACC, 2=WB. Each physical word holds two logical rows.
// Round-robin arbitration; one response slot per client. Writes are atomic
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
    typedef enum logic [1:0] {IDLE, READ_RESULT, WRITE_COMMIT} state_t;
    state_t state;
    logic [CW-1:0] next_client, selected, owner;
    logic selected_valid, address_ok;
    logic [AW-1:0] mapped_addr, saved_addr;
    logic selected_half, saved_half, saved_write, saved_accumulate;
    logic [31:0] saved_data, old_row, updated_row;
    logic [63:0] write_word, macro_data;
    logic macro_enable, macro_write;
    logic [AW-1:0] macro_addr;
    integer candidate;
    logic [23:0] row_limit, row_base;

    always_comb begin
        selected = '0;
        selected_valid = 1'b0;
        candidate = 0;
        for (int offset = 0; offset < CLIENTS; offset++) begin
            candidate = int'(next_client) + offset;
            if (candidate >= CLIENTS) candidate = candidate - CLIENTS;
            if (!selected_valid && req_valid[candidate] && !rsp_valid[candidate]) begin
                selected = CW'(candidate);
                selected_valid = 1'b1;
            end
        end
        row_limit = '0;
        row_base = '0;
        case (req_region[selected])
            0: begin row_limit = 24'(UB_ROWS); row_base = 0; end
            1: begin row_limit = 24'(ACC_ROWS); row_base = 24'(UB_ROWS); end
            2: begin row_limit = 24'(WB_ROWS); row_base = 24'(UB_ROWS+ACC_ROWS); end
            default: ;
        endcase
        address_ok = req_addr[selected] < row_limit;
        mapped_addr = AW'((row_base + req_addr[selected]) >> 1);
        selected_half = req_addr[selected][0];
        req_ready = '0;
        if (!rst && state == IDLE && selected_valid) req_ready[selected] = 1'b1;
    end

    assign busy = (state != IDLE) || (|req_valid) || (|rsp_valid);
    assign old_row = saved_half ? macro_data[63:32] : macro_data[31:0];
    always_comb begin
        updated_row = saved_data;
        if (saved_accumulate) begin
            updated_row[15:0] = fp16_add(old_row[15:0],saved_data[15:0]);
            updated_row[31:16] = fp16_add(old_row[31:16],saved_data[31:16]);
        end
    end
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
            owner <= '0;
            saved_addr <= '0;
            saved_half <= 0;
            saved_write <= 0;
            saved_accumulate <= 0;
            saved_data <= '0;
            write_word <= '0;
            rsp_valid <= '0;
            rsp_data <= '0;
            error <= 0;
        end else begin
            for (int i = 0; i < CLIENTS; i++)
                if (rsp_valid[i] && rsp_ready[i]) rsp_valid[i] <= 0;
            case (state)
                IDLE: if (selected_valid) begin
                    next_client <= selected == CW'(CLIENTS-1) ? '0 : selected + 1'b1;
                    if (!address_ok) begin
                        // Never truncate an out-of-range address into another region.
                        error <= 1;
                        if (!req_write[selected]) begin
                            rsp_valid[selected] <= 1;
                            rsp_data[selected] <= '0;
                        end
                    end else begin
                        owner <= selected;
                        saved_addr <= mapped_addr;
                        saved_half <= selected_half;
                        saved_write <= req_write[selected];
                        saved_accumulate <= req_accumulate[selected];
                        saved_data <= req_data[selected];
                        state <= READ_RESULT;
                    end
                end
                READ_RESULT: begin
                    // Macro sampled at preceding posedge, returned data at negedge.
                    if (saved_write) begin
                        write_word <= saved_half ? {updated_row,macro_data[31:0]}
                                                 : {macro_data[63:32],updated_row};
                        state <= WRITE_COMMIT;
                    end else begin
                        rsp_valid[owner] <= 1;
                        rsp_data[owner] <= old_row;
                        state <= IDLE;
                    end
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
