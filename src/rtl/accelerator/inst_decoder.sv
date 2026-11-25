// Instruction decoder and
// conservative resource-dependency scheduler.
module inst_decoder
    import tpu_pkg::*;
#(
    parameter int UB_ROWS = 32,
    parameter int WB_ROWS = 32
) (
    input logic clk,
    input logic rst,

    input inst_type inst_in,
    input logic     inst_write,
    output logic    decoder_busy,

    // WB
    input logic weight_busy,
    input logic weight_resource_busy,
    // UB
    input logic input_busy,
    input logic input_resource_busy,

    // VPU
    input logic vpu_busy,
    input logic vpu_read_wb,
    input logic vpu_resource_busy,

    // AB
    input logic activation_busy,
    input logic activation_resource_busy,

    // DMA
    input logic dma_busy,
    input logic dma_engine_busy,
    input logic dma_weight_resource_busy,
    input logic dma_buffer_resource_busy,
    input logic dma_acc_resource_busy,

    // Dispatch to different resources (ctrl)
    output inst_type dispatch_inst,
    output logic dispatch_weight_en,
    output logic dispatch_input_en,
    output logic dispatch_vpu_en,
    output vpu_inst_type dispatch_vpu_inst,
    output logic dispatch_vpu_read_wb,
    output logic vpu_address_error,
    output logic dispatch_activation_en,
    output logic dispatch_dma_en,

    output logic synchronize
);

    inst_type IR;

    weight_inst_type weight_IR;
    dram_inst_type dram_IR;
    vpu_inst_type vpu_IR;

    // Keep the existing DMA overlap for layouts with two 32-row UB ranges.
    logic vpu_bank_known, vpu_bank;
    logic disjoint_buffer_load;

    // Direct reads use one address space. The bit above the row selects WB.
    localparam int VPU_ROW_BITS = $clog2(UB_ROWS > WB_ROWS ? UB_ROWS : WB_ROWS);
    localparam int VPU_END_BITS = 1 + (VPU_ROW_BITS > LENGTH_WIDTH ? VPU_ROW_BITS : LENGTH_WIDTH);
    logic [VPU_ROW_BITS-1:0] vpu_row;
    logic [VPU_END_BITS-1:0] vpu_end;
    logic invalid_vpu_address;
    logic sparse_vpu;

    logic IR_valid;

    logic is_sync;
    logic is_activation;
    logic is_vpu;
    logic is_weight;
    logic is_input;
    logic is_dram_to_buffer;
    logic is_dram_to_weight;
    logic is_buffer_to_dram;
    logic is_acc_to_dram;
    logic is_dram_to_acc;
    logic is_acc_to_uart;
    logic is_dma;

    logic dispatch_ready;
    logic accept_inst;

    assign weight_IR = weight_inst_type'(IR);
    assign dram_IR = dram_inst_type'(IR);
    assign vpu_IR = vpu_inst_type'(IR);
    assign sparse_vpu = (vpu_IR.opcode & 8'hFE) == OPCODE_VPU_SCALAR_MUL;
    assign dispatch_vpu_read_wb = !sparse_vpu && vpu_IR.buffer_addr[VPU_ROW_BITS];
    assign vpu_row = vpu_IR.buffer_addr[VPU_ROW_BITS-1:0];
    assign vpu_end = VPU_END_BITS'(vpu_row) + VPU_END_BITS'(vpu_IR.length);
    assign invalid_vpu_address = !sparse_vpu && vpu_IR.length != 0 &&
        ((vpu_IR.buffer_addr >> (VPU_ROW_BITS+1)) != 0 ||
         vpu_end > (dispatch_vpu_read_wb ? VPU_END_BITS'(WB_ROWS) : VPU_END_BITS'(UB_ROWS)));

    always_comb begin
        dispatch_vpu_inst = vpu_IR;
        dispatch_vpu_inst.buffer_addr = buffer_addr_type'(vpu_row);
    end

    assign disjoint_buffer_load = is_dram_to_buffer && vpu_bank_known &&
        (dram_IR.sram_addr == (vpu_bank ? 16'd0 : 16'd32)) &&
        (IR.length == 8'd16 || IR.length == 8'd32);

    always_comb begin
        // instruction type decoding
        is_sync           = (IR.opcode == OPCODE_SYNCHRONIZE);
        is_activation     = (IR.opcode[7] && !is_sync);
        is_dma            = (IR.opcode[7:6] == 2'b01);
        is_vpu            = (IR.opcode[7:5] == 3'b001);
        is_input          = (IR.opcode[7:4] == 4'b0001);
        is_weight         = (IR.opcode[7:3] == 5'b00001);

        // IS_MEM!!!
        is_dram_to_buffer = is_dma && (IR.opcode[2:0] == mem_op_load_buffer);
        is_dram_to_weight = is_dma && (IR.opcode[2:0] == mem_op_load_weight);
        is_buffer_to_dram = is_dma && (IR.opcode[2:0] == mem_op_store_buffer);
        is_acc_to_dram    = is_dma && (IR.opcode[2:0] == mem_op_store_acc);
        is_dram_to_acc    = is_dma && (IR.opcode[2:0] == mem_op_load_acc);
        is_acc_to_uart    = is_dma && (IR.opcode[2:0] == mem_op_acc_to_uart);

        // check structural hazard
        // check data dependency
        dispatch_ready = 1'b0;

        if (IR_valid) begin
            if (is_sync) begin
                dispatch_ready = !(
                    weight_resource_busy     ||
                    vpu_resource_busy        ||
                    activation_resource_busy ||
                    //vpu_buffer_resource_busy ||
                    input_resource_busy      ||
                    dma_busy
                );
            end
            else if (is_weight) begin
                if (weight_IR.is_unified) begin
                    dispatch_ready =
                        !weight_busy &&
                        !vpu_resource_busy &&
                        !activation_resource_busy &&
                        !dma_buffer_resource_busy;
                end
                else begin
                    dispatch_ready =
                        !weight_busy &&
                        !vpu_resource_busy &&
                        !dma_weight_resource_busy;
                end
            end
            else if (is_vpu) begin
                dispatch_ready =
                    !vpu_busy &&
                    (!dispatch_vpu_read_wb || !dma_weight_resource_busy) &&
                    !weight_resource_busy &&
                    !activation_resource_busy &&
                    //!vpu_buffer_resource_busy &&
                    !dma_buffer_resource_busy &&
                    !dma_acc_resource_busy;
            end
            else if (is_activation) begin
                dispatch_ready =
                    !activation_busy &&
                    !weight_resource_busy &&
                    !vpu_resource_busy &&
                    //!vpu_buffer_resource_busy &&
                    !dma_buffer_resource_busy &&
                    !dma_acc_resource_busy;
            end
            else if (is_input) begin
                dispatch_ready =
                    !input_busy &&
                    !weight_resource_busy &&
                    !vpu_resource_busy &&
                    !activation_resource_busy &&
                    !dma_buffer_resource_busy;
            end
            else if (is_dram_to_weight) begin
                dispatch_ready =
                    !dma_busy &&
                    !(vpu_read_wb && vpu_resource_busy) &&
                    !weight_resource_busy;
            end
            else if (is_dram_to_buffer || is_buffer_to_dram) begin
                dispatch_ready =
                    ((!dma_busy && !vpu_resource_busy) ||
                     (vpu_resource_busy && disjoint_buffer_load && !dma_engine_busy)) &&
                    !weight_resource_busy &&
                    !input_resource_busy &&
                    //!vpu_buffer_resource_busy &&
                    !activation_resource_busy;
            end
            else if (is_acc_to_dram || is_dram_to_acc || is_acc_to_uart) begin
                dispatch_ready =
                    !dma_busy &&
                    !vpu_resource_busy &&
                    !activation_resource_busy;
            end
            else begin
                // NOP, HALT, and unsupported opcodes retire immediately.
                dispatch_ready = 1'b1;
            end
        end
    end

    assign decoder_busy           = IR_valid && !dispatch_ready;
    assign accept_inst            = inst_write && !decoder_busy;

    assign dispatch_inst          = IR;
    assign dispatch_weight_en     = dispatch_ready && is_weight;
    assign dispatch_vpu_en        = dispatch_ready && is_vpu && !invalid_vpu_address;
    assign dispatch_activation_en = dispatch_ready && is_activation;
    assign dispatch_input_en      = dispatch_ready && is_input;
    assign dispatch_dma_en        = dispatch_ready && is_dma;
    assign synchronize            = dispatch_ready && is_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            IR       <= '0;
            vpu_address_error <= 1'b0;
            IR_valid <= 1'b0;
            vpu_bank_known <= 1'b0;
            vpu_bank <= 1'b0;
        end
        else begin
            if (dispatch_ready && is_vpu && invalid_vpu_address)
                vpu_address_error <= 1'b1;

            if (dispatch_vpu_en) begin
                vpu_bank_known <= UB_ROWS >= 64 && !dispatch_vpu_read_wb && !sparse_vpu &&
                                  (vpu_IR.buffer_addr == 0 || vpu_IR.buffer_addr == 32) &&
                                  IR.length != 0 && IR.length <= 32;
                vpu_bank <= vpu_IR.buffer_addr[5];
            end
            if (accept_inst) begin
                IR       <= inst_in;
                IR_valid <= 1'b1;
            end
            else if (dispatch_ready) begin
                IR_valid <= 1'b0;
            end
        end
    end

endmodule
