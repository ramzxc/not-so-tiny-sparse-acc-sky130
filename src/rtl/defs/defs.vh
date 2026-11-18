`ifndef ACC_DEFS_VH
`define ACC_DEFS_VH

`ifndef DATA_WIDTH
`define DATA_WIDTH 16
`endif
`ifndef COMPUTE_WIDTH
`define COMPUTE_WIDTH 2
`endif

// FP16 arithmetic uses the module-local defs/fp16_math.vh functions.
// The instruction encoding is the tiny rebuild 16-bit ISA.
`define INST_WIDTH 16
`define INST_OP_WIDTH 3
`define INST_PAYLOAD_WIDTH 13

// Decoder outputs: packed EXEC fields and full ADDR/MEM/DATA word.
`define EXEC_INST_WIDTH 6
`define DATA_INST_WIDTH 16

`endif
