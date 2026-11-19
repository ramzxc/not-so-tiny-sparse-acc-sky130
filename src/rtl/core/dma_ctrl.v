`include "../defs/inst_defs.vh"

// Blocking, bit-preserving PSRAM -> SRAM copy. Reuses mem_itf's row buffer;
// no arithmetic, payload FIFO, or second QSPI engine is needed.
// One RUN copies row-bounded chunks through mem_itf's existing row buffer.
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
    output wire [9:0] mem_destination,
    output wire [2:0] mem_vectors,
    output wire busy,
    output reg error
);
    localparam [1:0] IDLE=0, READ_SEND=1, READ_WAIT=2;
    reg [1:0] state;
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
    wire [2:0] row_room=3'd4-{1'b0,destination[2:1]};
    assign mem_vectors=remaining < {5'b0,row_room} ? remaining[2:0] : row_room;
    assign mem_destination=destination;
    assign mem_read_continue=remaining>{5'b0,mem_vectors};
    assign mem_write=1'b0; // mem_itf commits the entire row before completion.
    assign mem_addr=source;
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
                            // Check the complete span before the first PSRAM read.
                            if (host_inst[9:8] != 0 || error || memory_error ||
                                (count != 0 && (source_end > 25'h0800000 || destination_end > 11'd1024)))
                                error <= 1;
                            else if (count != 0) begin
                                remaining <= count; state <= READ_SEND;
                            end
                        end
                        default: error <= 1;
                    endcase
                end
                READ_SEND: if (mem_ready) state <= READ_WAIT;
                READ_WAIT: if (mem_read_valid) begin
                    // Completion means the SRAM row has committed, not just QPI done.
                    if (remaining == {5'b0,mem_vectors}) begin
                        remaining<=0;state<=IDLE;
                    end else begin
                        remaining<=remaining-{5'b0,mem_vectors};
                        source<=source+{20'b0,mem_vectors,1'b0};
                        destination<=destination+{6'b0,mem_vectors,1'b0};
                        state<=READ_SEND;
                    end
                end
                default: begin error <= 1; state <= IDLE; end
            endcase
        end
    end
endmodule
