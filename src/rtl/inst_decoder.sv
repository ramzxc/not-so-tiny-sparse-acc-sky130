// Instruction decoder and
// conservative resource-dependency scheduler.
module inst_decoder
    import tpu_pkg::*;
(
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
    input logic vpu_resource_busy,

    // AB
    input logic activation_busy,
    input logic activation_resource_busy,

    // DMA
    input logic dma_busy,
    input logic dma_weight_resource_busy,
    input logic dma_buffer_resource_busy,
    input logic dma_acc_resource_busy,

    // Dispatch to different resources (ctrl)
    output inst_type dispatch_inst,
    output logic dispatch_weight_en,
    output logic dispatch_input_en,
    output logic dispatch_vpu_en,
    output logic dispatch_activation_en,
    output logic dispatch_dma_en,

    output logic synchronize
);

    inst_type IR;

    weight_inst_type weight_IR;

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
    logic is_dma;

    logic dispatch_ready;
    logic accept_inst;

    assign weight_IR = weight_inst_type'(IR);

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
                    !weight_resource_busy;
            end
            else if (is_dram_to_buffer || is_buffer_to_dram) begin
                dispatch_ready =
                    !dma_busy &&
                    !vpu_resource_busy &&
                    !weight_resource_busy &&
                    !input_resource_busy &&
                    //!vpu_buffer_resource_busy &&
                    !activation_resource_busy;
            end
            else if (is_acc_to_dram || is_dram_to_acc) begin
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
    assign dispatch_vpu_en        = dispatch_ready && is_vpu;
    assign dispatch_activation_en = dispatch_ready && is_activation;
    assign dispatch_input_en      = dispatch_ready && is_input;
    assign dispatch_dma_en        = dispatch_ready && is_dma;
    assign synchronize            = dispatch_ready && is_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            IR       <= '0;
            IR_valid <= 1'b0;
        end
        else begin
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
