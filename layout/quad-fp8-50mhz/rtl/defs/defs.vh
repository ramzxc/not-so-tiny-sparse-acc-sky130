`ifndef ACC_DEFS_VH
`define ACC_DEFS_VH

`ifndef DATA_WIDTH
`define DATA_WIDTH 8
`endif
`ifndef COMPUTE_WIDTH
`define COMPUTE_WIDTH 2
`endif

// FP8 E4M3FN, RNE, finite saturation. Two lanes share one physical MAC.
// The instruction encoding is the tiny rebuild 16-bit ISA.
`define INST_WIDTH 16
`define INST_OP_WIDTH 3
`define INST_PAYLOAD_WIDTH 13

// Decoder outputs: packed EXEC fields and full ADDR/MEM/DATA word.
`define EXEC_INST_WIDTH 6
`define DATA_INST_WIDTH 16

`endif
