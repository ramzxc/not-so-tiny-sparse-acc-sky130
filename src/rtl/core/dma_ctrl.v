`include "../defs/inst_defs.vh"

// Blocking, bit-preserving Flash -> SRAM copy. Shares mem_itf and its held
// read_data register; no arithmetic, FIFO, or second QSPI engine is needed.
// One RUN is one Flash read burst, paused while each SRAM vector commits.
module dma_ctrl (
    input wire clk, rst_n,
    input wire [15:0] host_inst,
    input wire host_valid,
    output wire host_ready,
    output wire [15:0] core_inst,
    output wire core_valid,
    input wire core_ready, units_idle,
    input wire [23:0] staging_addr,
    input wire mem_ready, mem_read_valid, memory_error,
    output wire mem_read, mem_write, mem_read_continue,
    output wire [23:0] mem_addr,
    output wire busy,
    output reg error
);
    localparam [2:0] IDLE=0, READ_SEND=1, READ_WAIT=2, WRITE_SEND=3, WRITE_WAIT=4;
    reg [2:0] state;
    reg [23:0] source;
    reg [9:0] destination;
    reg [7:0] remaining;
    wire is_dma = host_inst[15:13] == `OPCODE_DMA;
    wire [7:0] count = host_inst[7:0];
    wire [24:0] source_end = {1'b0,source} + {16'b0,count,1'b0};
    wire [10:0] destination_end = {1'b0,destination} + {2'b0,count,1'b0};
    assign busy = state != IDLE;
    assign host_ready = rst_n && !busy && (is_dma ? units_idle : core_ready);
    assign core_inst = host_inst;
    assign core_valid = rst_n && !busy && host_valid && !is_dma;
    assign mem_read = rst_n && state == READ_SEND && !memory_error;
    // Keep the Flash transaction open across intermediate SRAM writes.
    assign mem_read_continue = remaining > 1;
    assign mem_write = rst_n && state == WRITE_SEND && !memory_error;
    assign mem_addr = (state == READ_SEND || state == READ_WAIT) ? source : {14'b0,destination};
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; source <= 0; destination <= 0; remaining <= 0; error <= 0;
        end else if (busy && memory_error) begin
            error <= 1;
            if (mem_ready) state <= IDLE;
        end else begin
            case (state)
                IDLE: if (host_valid && host_ready && is_dma) begin
                    case (host_inst[12:10])
                        `DMA_SOURCE: begin
                            if (host_inst[9:0] != 0) error <= 1;
                            else source <= staging_addr;
                        end
                        `DMA_DEST: begin
                            if (host_inst[9:0] != 0 || staging_addr > 24'd1022 || staging_addr[0] != 0)
                                error <= 1;
                            else destination <= staging_addr[9:0];
                        end
                        `DMA_RUN: begin
                            // Check the complete span before the first Flash read.
                            if (host_inst[9:8] != 0 || error || memory_error ||
                                (count != 0 && (source_end > 25'h1000000 || destination_end > 11'd1024)))
                                error <= 1;
                            else if (count != 0) begin
                                remaining <= count; state <= READ_SEND;
                            end
                        end
                        default: error <= 1;
                    endcase
                end
                READ_SEND: if (mem_ready) state <= READ_WAIT;
                READ_WAIT: if (mem_read_valid) state <= WRITE_SEND;
                WRITE_SEND: if (mem_ready) state <= WRITE_WAIT;
                WRITE_WAIT: if (mem_ready) begin
                    // mem_itf only raises ready after SRAM_COMMIT. Until then
                    // host dispatch remains blocked, including a queued SYNC.
                    if (remaining == 1) begin
                        remaining <= 0; state <= IDLE;
                    end else begin
                        remaining <= remaining - 1'b1;
                        source <= source + 24'd2;
                        destination <= destination + 10'd2;
                        state <= READ_SEND;
                    end
                end
                default: begin error <= 1; state <= IDLE; end
            endcase
        end
    end
endmodule
