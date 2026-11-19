`ifndef MEM_DEFS_VH
`define MEM_DEFS_VH
// Logical external device 00 now means board-prepared PSRAM A.
`define MEM_ADDR_WIDTH 24
`define MEM_DEVICE_WIDTH 2
`define MEM_PSRAM 2'b00
// Legacy source alias only; there is no Flash datapath in this build.
`define MEM_FLASH `MEM_PSRAM
`define MEM_SRAM  2'b01
// 10/11 are reserved; the second PSRAM is not selected.
`endif
