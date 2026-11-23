// THIS TPU consists of following components
// - DRAM
// - Weight Buffer (WB) / Weight Cache
// - Unified Buffer (UB): Stores Input & Output
// - Accumulation Buffer (AB): Stores partial output
// - Activation (Act): Activation functional unit
// - Vector Processor (VPU): Vector processor
`ifndef ACC_SRAM_BYTES
`define ACC_SRAM_BYTES 512
`endif
package tpu_pkg;
    localparam int DEFAULT_SRAM_BYTES = `ACC_SRAM_BYTES;

    // DRAM remains byte-addressable. BYTE_WIDTH is the addressable storage unit,
    // while each TPU architectural data element is E4M3FN (FP8).
    // FIXME -> fixed point & run-time configurable quantization
    parameter int BYTE_WIDTH              = 8;
    parameter int FP8_WIDTH               = 8;
    parameter int FP8_BYTES               = FP8_WIDTH / BYTE_WIDTH;

    ////////////////////////////////========
    //                                    //
    //      Instruction format bitwidth   //
    //                                    //
    ////////////////////////////////========

    parameter int INSTRUCTION_WIDTH      = 64;
    parameter int BUFFER_ADDR_WIDTH      = 16;
    parameter int ACCUMULATOR_ADDR_WIDTH = 8;
    parameter int WEIGHT_ADDR_WIDTH      = 24;
    parameter int DRAM_ADDR_WIDTH        = 32;
    parameter int OPCODE_WIDTH           = 8;
    parameter int LENGTH_WIDTH           = 8;

    ////////////////////////////
    //                        //
    //      ISA OPCODE LIST   //
    //                        //
    ////////////////////////////

    // Nop
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_NOP        = 8'h00;
    // Halt the operation
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_HALT       = 8'h02;

    // Perform an activation function
    // From AB -> Act -> UB
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_ACTIVATE    = 8'h80;
    // Execute VPU (Vector MAC Unit)
    // - (Use preloaded weight)
    // - Load data from the UB
    // - Store/Accumulate results to the AB
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU        = 8'h20;
    // Transfer data from the WB -> VPU
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_WEIGHT     = 8'h08;
    // Transfer data from the UB -> VPU
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_INPUT      = 8'h10;

    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_MUL = 8'h20; // 0010_0000
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_ADD = 8'h22; // 0010_0010
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_VEC_SUB = 8'h24; // 0010_0100

    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_MUL = 8'h30; // 0011_0000
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_ADD = 8'h32; // 0011_0010
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_VPU_SCALAR_SUB = 8'h34; // 0011_0100

    // Memory transfer ISA
    // SRC_TO_DST
    // the last three bits become the sub-opcode
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_MEM            = 8'h40;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_BUFFER = 8'h40;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_WEIGHT = 8'h41;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_BUFFER_TO_DRAM = 8'h42;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_ACC_TO_DRAM    = 8'h43;
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_DRAM_TO_ACC    = 8'h44;

    // Synchronize
    // The host waits for the TPU until it flushes the instructions
    localparam logic [OPCODE_WIDTH-1:0] OPCODE_SYNCHRONIZE = 8'hFF;

    ////////////////////////////
    //                        //
    //      TYPE DEFINITION   //
    //                        //
    ////////////////////////////

    // Byte type is used only by the byte-addressable DRAM model and beat packers.
    typedef logic [BYTE_WIDTH-1:0] byte_type;

    // All architectural operands, products, sums, and state use E4M3FN.
    `include "fp8_math.vh"

    // Address types for the buffers and dram
    typedef logic [BUFFER_ADDR_WIDTH-1:0]      buffer_addr_type;
    typedef logic [DRAM_ADDR_WIDTH-1:0]        dram_addr_type;
    typedef logic [ACCUMULATOR_ADDR_WIDTH-1:0] accumulator_addr_type;
    typedef logic [WEIGHT_ADDR_WIDTH-1:0]      weight_addr_type;

    // Cache Replacement Policy Type (3 bits for 5 policies)
    typedef enum logic [2:0] {
        POLICY_DECAYED_LFU, // Baseline 1: Decayed LFU
        POLICY_SLRU,        // Baseline 2: Segmented LRU (Scan-Resistant)
        POLICY_FIFO,        // Ultra-low power fallback
        POLICY_CUSTOM,      // Custom Hybrid Policy (Transplanted from C++)
        POLICY_RANDOM       // Random Replacement
    } repl_policy_e;

    ////////////////////////////////
    //                            //
    //      CONSTANT DEFINITION   //
    //                            //
    ////////////////////////////////

    localparam fp8_type FP8_ONE = 8'h38, FP8_NEG_ONE = 8'hb8;

    typedef enum logic [3:0] {
        no_activation,
        relu,
        relu6,
        crelu,
        elu,
        selu,
        softplus,
        softsign,
        dropout,
        sigmoid,
        tanh,
        heaviside_step
    } activation_type;

    typedef enum logic [2:0] {
        mem_op_load_buffer,
        mem_op_load_weight,
        mem_op_store_buffer,
        mem_op_store_acc,
        mem_op_load_acc,
        mem_op_none
    } memory_op_type;

    typedef enum logic [2:0] {
        vpu_op_mul,
        vpu_op_add,
        vpu_op_sub,
        vpu_op_none
    } vpu_op_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-WEIGHT_ADDR_WIDTH-BUFFER_ADDR_WIDTH-1-OPCODE_WIDTH-1:0] empty;
        logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr;
        logic [BUFFER_ADDR_WIDTH-1:0] unified_addr;
        logic is_unified;
        logic [OPCODE_WIDTH-1:0] opcode;
    } weight_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] input_addr;
        logic [OPCODE_WIDTH-1:0] opcode;
    } input_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-ACCUMULATOR_ADDR_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] buffer_addr;
        logic [ACCUMULATOR_ADDR_WIDTH-1:0] acc_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } vpu_inst_type;

    typedef struct packed {
        logic [DRAM_ADDR_WIDTH-1:0] dram_addr;
        logic [BUFFER_ADDR_WIDTH-1:0] sram_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } dram_inst_type;

    typedef struct packed {
        logic [INSTRUCTION_WIDTH-BUFFER_ADDR_WIDTH-ACCUMULATOR_ADDR_WIDTH-LENGTH_WIDTH-OPCODE_WIDTH-1:0] empty;
        logic [BUFFER_ADDR_WIDTH-1:0] buffer_addr;
        logic [ACCUMULATOR_ADDR_WIDTH-1:0] acc_addr;
        logic [LENGTH_WIDTH-1:0] length;
        logic [OPCODE_WIDTH-1:0] opcode;
    } activate_inst_type;

    typedef union packed {
        inst_type          generic;
        weight_inst_type   weight;
        vpu_inst_type      vpu;
        dram_inst_type     dram;
        activate_inst_type activate;
        logic [INSTRUCTION_WIDTH-1:0] raw;
    } instruction_union_type;

endpackage
