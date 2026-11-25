`ifndef MEM_DEFS_VH
`define MEM_DEFS_VH
// Keep tiny's Flash selector; use its reserved selector for local SRAM.
`define MEM_ADDR_WIDTH 24
`define MEM_DEVICE_WIDTH 2
`define MEM_FLASH 2'b00
`define MEM_SRAM  2'b01
// 10/11 are not connected: this SKY130 design does not use PSRAM.
`endif
