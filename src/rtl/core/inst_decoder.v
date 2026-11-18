`include "../defs/defs.vh"
`include "../defs/inst_defs.vh"

// Dispatch the FIFO head directly. No local instruction or pending register.
module inst_decoder (
    input  wire rst_n,
    input  wire [`INST_WIDTH-1:0] inst_in,
    input  wire inst_in_val,
    output reg decoder_rdy,

    input  wire exec_rdy,
    input  wire data_rdy,

    output wire [`EXEC_INST_WIDTH-1:0] exec_inst_out,
    output reg exec_inst_out_val,
    output wire [`DATA_INST_WIDTH-1:0] data_inst_out,
    output reg data_inst_out_val
);
    wire [2:0] opcode = inst_in[15:13];
    assign exec_inst_out = inst_in[12:7]; // accumulate, arithmetic, activation
    assign data_inst_out = inst_in;      // ADDR needs its full 12-bit fragment

    always @(*) begin
        decoder_rdy       = 0;
        exec_inst_out_val = 0;
        data_inst_out_val = 0;

        if (rst_n) begin
            case (opcode)
                `OPCODE_ADDR, `OPCODE_MEM, `OPCODE_DATA: begin
                    decoder_rdy       = data_rdy;
                    data_inst_out_val = inst_in_val && data_rdy;
                end

                `OPCODE_EXEC: begin
                    decoder_rdy       = exec_rdy;
                    exec_inst_out_val = inst_in_val && exec_rdy;
                end

                // Independent units may overlap. Insert SYNC before consuming
                // a pending memory operand or before reusing a result.
                `OPCODE_SYNC: decoder_rdy = exec_rdy && data_rdy;

                default: decoder_rdy = 1; // NOP and reserved opcodes
            endcase
        end
    end
endmodule
