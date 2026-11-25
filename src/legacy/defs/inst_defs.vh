`ifndef INST_DEFS_VH
`define INST_DEFS_VH

// opcode
`define OPCODE_NOP    3'b000
`define OPCODE_ADDR   3'b001
`define OPCODE_MEM    3'b010
`define OPCODE_EXEC   3'b011
`define OPCODE_DATA   3'b100
`define OPCODE_MICRO  3'b101
`define OPCODE_DMA    3'b110
`define OPCODE_SYNC   3'b111

// Blocking Flash -> SRAM copy. Address commands capture ordinary ADDR.
`define DMA_SOURCE 3'd0
`define DMA_DEST   3'd1
`define DMA_RUN    3'd2
`define INST_DMA_SOURCE {`OPCODE_DMA, `DMA_SOURCE, 10'b0}
`define INST_DMA_DEST   {`OPCODE_DMA, `DMA_DEST, 10'b0}
// Count is an 8-bit number of 4-byte vectors (0..128); zero is a no-op.
`define INST_DMA_RUN(count) {`OPCODE_DMA, `DMA_RUN, 2'b0, (count)}

// Fixed column sequencer configuration. Address commands capture the current ADDR.
`define MICRO_INPUT   3'd0
`define MICRO_WEIGHT  3'd1
`define MICRO_ACC     3'd2
`define MICRO_GROUPS  3'd3
`define MICRO_COLUMNS 3'd4
`define MICRO_RUN     3'd5
`define MICRO_BATCH   3'd6
// 1..128; reset default is 1. Use an 8-bit count.
`define INST_MICRO_BATCH(count) {`OPCODE_MICRO, `MICRO_BATCH, 2'b0, (count)}
`define INST_MICRO_INPUT(sram) {`OPCODE_MICRO, `MICRO_INPUT, 9'b0, (sram)}
`define INST_MICRO_WEIGHT(sram) {`OPCODE_MICRO, `MICRO_WEIGHT, 9'b0, (sram)}
`define INST_MICRO_ACC {`OPCODE_MICRO, `MICRO_ACC, 10'b0}
`define INST_MICRO_GROUPS(count) {`OPCODE_MICRO, `MICRO_GROUPS, 2'b0, (count)}
`define INST_MICRO_COLUMNS(count) {`OPCODE_MICRO, `MICRO_COLUMNS, 2'b0, (count)}
`define INST_MICRO_RUN(sparse) {`OPCODE_MICRO, `MICRO_RUN, 9'b0, (sparse)}

// opcode: nop
`define NOP 16'b0000000000000000

// opcode: addr
`define ADDR_LOW  1'b0
`define ADDR_HIGH 1'b1

// opcode: mem
`define MEM_READ  1'b0
`define MEM_WRITE 1'b1

// opcode: execute -> VPU
`define VPU_ADD 2'b00
`define VPU_SUB 2'b01
`define VPU_MUL 2'b10

`define VPU_OVERWRITE  1'b0
`define VPU_ACCUMULATE 1'b1

// opcode: execute -> ACT
`define ACT_NOP     3'b000
`define ACT_RELU    3'b001
`define ACT_TANH    3'b010
`define ACT_SIGMOID 3'b011
`define ACT_STEP    3'b100

// opcode: DATA
`define DATA_LOAD  1'b0 // load data for exec_unit
`define DATA_STORE 1'b1 // store to SRAM

`define DATA_DENSE 1'b0
`define DATA_SPARSE 1'b1

`define DATA_INPUT  1'b0
`define DATA_WEIGHT 1'b1

// opcode: SYNC
`define SYNC 16'b1111111111111111

// INST PRESET: complete 16-bit instructions.
// ADDR arguments must be 12 bits (for example, 12'h123).
// These layouts define the new ISA; the decoder must use the same fields.

// NOP / SYNC
`define INST_NOP  `NOP
`define INST_SYNC `SYNC

// ADDR: [15:13] opcode, [12] low/high, [11:0] address fragment
`define INST_ADDR_LOW(addr)  {`OPCODE_ADDR, `ADDR_LOW,  (addr)}
`define INST_ADDR_HIGH(addr) {`OPCODE_ADDR, `ADDR_HIGH, (addr)}

// MEM: [15:13] opcode, [12] read/write, [11:10] device, [9] SRAM accumulate, [8] post-increment, [7:0] reserved.
// Device: 00=Flash, 01=local SRAM; 10/11 unsupported on this design.
`define INST_MEM_READ_DEVICE(dev)  {`OPCODE_MEM, `MEM_READ,  (dev), 10'b0}
`define INST_MEM_WRITE_DEVICE(dev) {`OPCODE_MEM, `MEM_WRITE, (dev), 10'b0}
`define INST_MEM_READ  `INST_MEM_READ_DEVICE(2'b00)
`define INST_MEM_WRITE `INST_MEM_WRITE_DEVICE(2'b00)
`define INST_SRAM_READ `INST_MEM_READ_DEVICE(2'b01)
`define INST_SRAM_WRITE `INST_MEM_WRITE_DEVICE(2'b01)
// SRAM-only memory accumulation uses formerly reserved MEM bit 9.
`define INST_SRAM_ACCUMULATE {`OPCODE_MEM, `MEM_WRITE, 2'b01, 1'b1, 9'b0}

// Optional post-increment (+4 bytes) for any MEM preset, including accumulation.
`define INST_MEM_POSTINC(inst) ((inst) | 16'h0100)
`define INST_SRAM_READ_INC `INST_MEM_POSTINC(`INST_SRAM_READ)
`define INST_SRAM_WRITE_INC `INST_MEM_POSTINC(`INST_SRAM_WRITE)
`define INST_SRAM_ACCUMULATE_INC `INST_MEM_POSTINC(`INST_SRAM_ACCUMULATE)

// EXEC: VPU and ACT travel together in one instruction.
// [15:13] opcode, [12] accumulate, [11:10] VPU operation,
// [9:7] activation, [6:0] reserved.
// ACT_NOP passes the VPU result through without activation.
// Arguments must be 1-bit accumulate, 2-bit VPU op and 3-bit ACT op.
`define INST_EXEC(acc, vpu, act) {`OPCODE_EXEC, (acc), (vpu), (act), 7'b0}

// Accumulation is supported for MUL only.

// ADD with overwrite
`define INST_EXEC_ADD_NOP              `INST_EXEC(`VPU_OVERWRITE, `VPU_ADD, `ACT_NOP)
`define INST_EXEC_ADD_RELU             `INST_EXEC(`VPU_OVERWRITE, `VPU_ADD, `ACT_RELU)
`define INST_EXEC_ADD_TANH             `INST_EXEC(`VPU_OVERWRITE, `VPU_ADD, `ACT_TANH)
`define INST_EXEC_ADD_SIGMOID          `INST_EXEC(`VPU_OVERWRITE, `VPU_ADD, `ACT_SIGMOID)
`define INST_EXEC_ADD_STEP             `INST_EXEC(`VPU_OVERWRITE, `VPU_ADD, `ACT_STEP)

// SUB with overwrite
`define INST_EXEC_SUB_NOP              `INST_EXEC(`VPU_OVERWRITE, `VPU_SUB, `ACT_NOP)
`define INST_EXEC_SUB_RELU             `INST_EXEC(`VPU_OVERWRITE, `VPU_SUB, `ACT_RELU)
`define INST_EXEC_SUB_TANH             `INST_EXEC(`VPU_OVERWRITE, `VPU_SUB, `ACT_TANH)
`define INST_EXEC_SUB_SIGMOID          `INST_EXEC(`VPU_OVERWRITE, `VPU_SUB, `ACT_SIGMOID)
`define INST_EXEC_SUB_STEP             `INST_EXEC(`VPU_OVERWRITE, `VPU_SUB, `ACT_STEP)

// MUL with overwrite
`define INST_EXEC_MUL_NOP              `INST_EXEC(`VPU_OVERWRITE, `VPU_MUL, `ACT_NOP)
`define INST_EXEC_MUL_RELU             `INST_EXEC(`VPU_OVERWRITE, `VPU_MUL, `ACT_RELU)
`define INST_EXEC_MUL_TANH             `INST_EXEC(`VPU_OVERWRITE, `VPU_MUL, `ACT_TANH)
`define INST_EXEC_MUL_SIGMOID          `INST_EXEC(`VPU_OVERWRITE, `VPU_MUL, `ACT_SIGMOID)
`define INST_EXEC_MUL_STEP             `INST_EXEC(`VPU_OVERWRITE, `VPU_MUL, `ACT_STEP)

// MUL with accumulation
`define INST_EXEC_MUL_ACC_NOP          `INST_EXEC(`VPU_ACCUMULATE, `VPU_MUL, `ACT_NOP)
`define INST_EXEC_MUL_ACC_RELU         `INST_EXEC(`VPU_ACCUMULATE, `VPU_MUL, `ACT_RELU)
`define INST_EXEC_MUL_ACC_TANH         `INST_EXEC(`VPU_ACCUMULATE, `VPU_MUL, `ACT_TANH)
`define INST_EXEC_MUL_ACC_SIGMOID      `INST_EXEC(`VPU_ACCUMULATE, `VPU_MUL, `ACT_SIGMOID)
`define INST_EXEC_MUL_ACC_STEP         `INST_EXEC(`VPU_ACCUMULATE, `VPU_MUL, `ACT_STEP)

// DATA: [15:13] opcode, [12] load/store, [11] dense/sparse,
//       [10] input/weight, [9] input element, [8] scalar broadcast (LOAD only).
//       [7:0] reserved; STORE ignores selection fields.
`define INST_DATA(mode, sparse, target) {`OPCODE_DATA, (mode), (sparse), (target), 10'b0}
`define INST_DATA_LOAD_INPUT_DENSE  `INST_DATA(`DATA_LOAD, `DATA_DENSE,  `DATA_INPUT)
`define INST_DATA_LOAD_INPUT_SPARSE `INST_DATA(`DATA_LOAD, `DATA_SPARSE, `DATA_INPUT)
`define INST_DATA_LOAD_WEIGHT_DENSE `INST_DATA(`DATA_LOAD, `DATA_DENSE,  `DATA_WEIGHT)
`define INST_DATA_LOAD_WEIGHT_SPARSE `INST_DATA(`DATA_LOAD, `DATA_SPARSE, `DATA_WEIGHT)
// Scalar column mode: select element 0/1 without consuming or reloading it.
// These DATA LOAD commands configure the following MEM destination as well.
`define INST_DATA_SCALAR(sparse, target, cur) {`OPCODE_DATA, `DATA_LOAD, (sparse), (target), (cur), 1'b1, 8'b0}
`define INST_DATA_WEIGHT_SCALAR(cur) `INST_DATA_SCALAR(`DATA_DENSE, `DATA_WEIGHT, (cur))
`define INST_DATA_WEIGHT_SCALAR_SPARSE(cur) `INST_DATA_SCALAR(`DATA_SPARSE, `DATA_WEIGHT, (cur))
`define INST_DATA_STORE             `INST_DATA(`DATA_STORE, `DATA_DENSE, `DATA_INPUT)

`endif
