`include "../defs/defs.vh"
`include "../defs/inst_defs.vh"
`include "../defs/mem_defs.vh"

// ADDR/MEM/DATA terminate here. A MEM transfers one complete vector.
// The memory backend handles any physical bus serialization.
// DATA LOAD selects the destination and sparse mode for following MEM READs.
// DATA STORE snapshots exec's held result; MEM WRITE writes that snapshot.
module data_ctrl (
    input  wire clk,
    input  wire rst_n,
    input  wire [`DATA_INST_WIDTH-1:0] data_inst_in,
    input  wire data_inst_in_val,
    output wire data_rdy,

    input  wire [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] exec_data_in,
    input  wire exec_data_in_val,
    output reg [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] exec_data_out,
    output reg exec_data_out_val,
    output reg exec_data_is_weight,

    // Direct connection to mem_itf. rdy means the whole transaction is idle.
    input  wire mem_itf_rdy,
    output wire read_en,
    output wire write_en,
    output reg write_accumulate,
    output wire [`MEM_ADDR_WIDTH-1:0] addr,
    output reg [`MEM_DEVICE_WIDTH-1:0] device,
    output wire [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] write_data,
    input  wire [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] read_data,
    input  wire read_data_val,
    output reg input_scalar_mode,
    output reg input_select,
    output wire input_sparse,
    output wire [1:0] loaded_input_zero_mask
);
    localparam [1:0] IDLE = 0, SEND = 1, WAIT = 2, DELIVER = 3;
    reg [1:0] state;
    reg [`MEM_ADDR_WIDTH-1:0] base_addr;
    reg [`DATA_WIDTH*`COMPUTE_WIDTH-1:0] write_buffer;
    reg [`COMPUTE_WIDTH-1:0] input_zero_mask;
    wire [`COMPUTE_WIDTH-1:0] lane_zero;
    genvar lane;
    generate for (lane = 0; lane < `COMPUTE_WIDTH; lane = lane + 1) begin : zero_detect
        assign lane_zero[lane] = read_data[lane*`DATA_WIDTH +: (`DATA_WIDTH-1)] == 0;
    end endgenerate
    assign loaded_input_zero_mask = input_zero_mask;
    reg sparse_en;
    assign input_sparse = sparse_en;
    wire input_zero = input_scalar_mode ? input_zero_mask[input_select] : &input_zero_mask;
    reg load_weight;
    reg write_reg;
    reg auto_increment;
    localparam [23:0] VECTOR_BYTES = `DATA_WIDTH * `COMPUTE_WIDTH / 8;
    reg result_valid;

    wire [2:0] opcode = data_inst_in[15:13];
    wire store_result = opcode == `OPCODE_DATA && data_inst_in[12] == `DATA_STORE;
    wire accept = data_inst_in_val && data_rdy;

    // STORE waits for at least one result, not for a coincident valid pulse.
    // Software uses SYNC if it needs a newer EXEC result instead of the held one.
    assign data_rdy = rst_n && state == IDLE && mem_itf_rdy &&
        (!store_result || result_valid);
    // Lane 0 occupies the lowest byte address and least-significant data bits.
    // MEM bit 8 optionally advances the address after the complete vector.
    assign addr = base_addr;
    assign write_data = write_buffer;
    assign read_en  = rst_n && state == SEND && !write_reg;
    assign write_en = rst_n && state == SEND &&  write_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            state               <= IDLE;
            load_weight         <= 0;
            sparse_en           <= 0;
            input_zero_mask     <= 0;
            input_scalar_mode   <= 0;
            input_select        <= 0;
            write_reg           <= 0;
            auto_increment      <= 0;
            write_accumulate    <= 0;
            result_valid        <= 0;
            base_addr           <= 0;
            device              <= `MEM_FLASH;
            write_buffer        <= 0;
            exec_data_out       <= 0;
            exec_data_out_val   <= 0;
            exec_data_is_weight <= 0;
        end else begin
            exec_data_out_val <= 0;
            if (exec_data_in_val) result_valid <= 1;
            // DELIVER includes sparse-skipped reads. Increment once on retirement,
            // never while a memory request is stalled. Rejected requests also retire.
            // Saturate rather than wrapping a 24-bit overflow into low memory.
            if (auto_increment && (state == DELIVER ||
                (state == WAIT && write_reg && mem_itf_rdy))) begin
                if (base_addr > 24'hffffff - VECTOR_BYTES)
                    base_addr <= 24'hffffff;
                else base_addr <= base_addr + VECTOR_BYTES;
            end

            case (state)
                IDLE: if (accept) begin
                    case (opcode)
                        `OPCODE_ADDR: begin
                            if (data_inst_in[12] == `ADDR_HIGH)
                                base_addr[23:12] <= data_inst_in[11:0];
                            else
                                base_addr[11:0] <= data_inst_in[11:0];
                        end

                        `OPCODE_DATA: begin
                            if (data_inst_in[12] == `DATA_LOAD) begin
                                load_weight <= data_inst_in[10];
                                sparse_en   <= data_inst_in[11];
                                input_scalar_mode <= data_inst_in[8];
                                input_select <= data_inst_in[9];
                            end else begin
                                write_buffer <= exec_data_in;
                            end
                        end

                        `OPCODE_MEM: begin
                            device        <= data_inst_in[11:10];
                            write_reg <= data_inst_in[12];
                            write_accumulate <= data_inst_in[9];
                            auto_increment <= data_inst_in[8];
                            if (data_inst_in[12] == `MEM_READ &&
                                load_weight && sparse_en && input_zero) begin
                                // No bus request. Supply zero instead of an old
                                // weight (which could even be NaN in FP8).
                                exec_data_out       <= 0;
                                exec_data_out_val   <= 1;
                                exec_data_is_weight <= 1;
                                state               <= DELIVER;
                            end else begin
                                state <= SEND;
                            end
                        end

                        default: begin end
                    endcase
                end

                SEND: if (mem_itf_rdy) state <= WAIT;

                WAIT: begin
                    if (!write_reg && read_data_val) begin
                        exec_data_out       <= read_data;
                        exec_data_out_val   <= 1;
                        exec_data_is_weight <= load_weight;
                        if (!load_weight) input_zero_mask <= lane_zero;
                        state <= DELIVER;
                    end else if (write_reg && mem_itf_rdy) begin
                        state <= IDLE;
                    end
                end

                // exec_unit captures the operand at this edge. A following
                // SYNC cannot retire before that capture has completed.
                DELIVER: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (`DATA_WIDTH != 8 || `COMPUTE_WIDTH < 1)
            $fatal(1, "data_ctrl requires FP8 elements and a valid positive lane count");
    end
    // Invalid regions are rejected by mem_itf and reported on its error output.
`endif
endmodule
