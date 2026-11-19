`include "defs/defs.vh"
`include "defs/mem_defs.vh"

// Vector memory interface with a byte handshake to QSPI. DMA reads keep
// the Flash transaction open within/across vectors; ordinary MEM stays single-byte.
// Device 01 adds flat 512 B SRAM, with two 32-bit vectors per 64-bit word.
module mem_itf (
    input wire clk, rst_n, read_en, write_en, write_accumulate,
    input wire read_burst, read_continue,
    output wire rdy,
    input wire [23:0] addr,
    input wire [1:0] device,
    input wire [31:0] write_data,
    output reg [31:0] read_data,
    output reg read_data_val, error,
    output wire qspi_req_val,
    input wire qspi_req_rdy,
    output wire qspi_req_write, qspi_req_continue,
    output wire [23:0] qspi_req_addr,
    output wire [1:0] qspi_req_device,
    output wire [7:0] qspi_req_data,
    input wire [7:0] qspi_read_data,
    input wire qspi_read_data_val
);
    `include "defs/fp16_math.vh"
    typedef enum logic [3:0] {
        IDLE, FLASH_SEND, FLASH_WAIT, SRAM_READ, SRAM_WAIT,
        ADD_LOW, ADD_HIGH, SRAM_WRITE, SRAM_COMMIT
    } state_t;
    state_t state;
    reg [23:0] saved_addr;
    reg [31:0] saved_data, old_vector;
    reg saved_write, saved_accumulate, saved_burst, saved_continue;
    reg [1:0] byte_index;
    reg [63:0] write_word;
    wire [63:0] macro_data;
    wire upper = saved_addr[2];
    wire high_lane = state == ADD_HIGH;
    wire [15:0] sum = fp16_add(old_vector[high_lane*16 +: 16],
                                saved_data[high_lane*16 +: 16]);
    assign rdy = rst_n && state == IDLE;
    assign qspi_req_val = rst_n && state == FLASH_SEND;
    assign qspi_req_write = saved_write;
    assign qspi_req_continue = saved_burst && (byte_index != 3 || saved_continue);
    assign qspi_req_addr = saved_addr + {22'b0, byte_index};
    assign qspi_req_device = `MEM_FLASH;
    assign qspi_req_data = saved_data[byte_index*8 +: 8];
    shared_sram #(.SRAM_BYTES(512)) memory (
        .clk(clk), .enable(rst_n && (state == SRAM_READ || state == SRAM_WRITE)),
        .write(state == SRAM_WRITE), .addr(saved_addr[8:3]),
        .wdata(write_word), .rdata(macro_data)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            saved_addr <= 0; saved_data <= 0; old_vector <= 0; write_word <= 0;
            saved_write <= 0; saved_accumulate <= 0; byte_index <= 0;
            saved_burst <= 0; saved_continue <= 0;
            read_data <= 0; read_data_val <= 0; error <= 0;
        end else begin
            read_data_val <= 0;
            case (state)
                IDLE: if (read_en || write_en) begin
                    // Validate the WHOLE vector before the first access.
                    // No truncation/wrap, no partial writes from invalid vectors.
                    if ((read_en && write_en) || device[1] ||
                        (device == `MEM_SRAM && (addr >= 24'd512 || addr[1:0] != 0)) ||
                        (device == `MEM_FLASH && (addr > 24'hfffffc || write_accumulate)) ||
                        (write_accumulate && !write_en)) begin
                        error <= 1;
                        read_data <= 0;
                        read_data_val <= read_en;
                    end else begin
                        saved_addr <= addr;
                        saved_data <= write_data;
                        saved_write <= write_en;
                        saved_accumulate <= write_accumulate;
                        saved_burst <= read_burst && read_en && device == `MEM_FLASH;
                        saved_continue <= read_continue;
                        byte_index <= 0;
                        state <= device == `MEM_SRAM ? SRAM_READ : FLASH_SEND;
                    end
                end
                FLASH_SEND: if (qspi_req_rdy) state <= FLASH_WAIT;
                FLASH_WAIT: if (qspi_read_data_val) begin
                    if (!saved_write) read_data[byte_index*8 +: 8] <= qspi_read_data;
                    if (byte_index == 3) begin
                        read_data_val <= !saved_write;
                        state <= IDLE;
                    end else begin
                        byte_index <= byte_index + 1'b1;
                        state <= FLASH_SEND;
                    end
                end
                // OpenRAM samples controls on posedge and returns on negedge.
                SRAM_READ: state <= SRAM_WAIT;
                SRAM_WAIT: begin
                    if (!saved_write) begin
                        read_data <= upper ? macro_data[63:32] : macro_data[31:0];
                        read_data_val <= 1;
                        state <= IDLE;
                    end else begin
                        old_vector <= upper ? macro_data[63:32] : macro_data[31:0];
                        if (saved_accumulate) begin
                            write_word <= macro_data;
                            state <= ADD_LOW;
                        end else begin
                            write_word <= upper ? {saved_data, macro_data[31:0]} :
                                                  {macro_data[63:32], saved_data};
                            state <= SRAM_WRITE;
                        end
                    end
                end
                ADD_LOW: begin
                    write_word[(upper ? 32 : 0) +: 16] <= sum;
                    state <= ADD_HIGH;
                end
                ADD_HIGH: begin
                    write_word[(upper ? 48 : 16) +: 16] <= sum;
                    state <= SRAM_WRITE;
                end
                SRAM_WRITE: state <= SRAM_COMMIT;
                SRAM_COMMIT: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial if (`DATA_WIDTH != 16 || `COMPUTE_WIDTH != 2)
        $fatal(1, "This SRAM interface requires two FP16 lanes");
`endif
endmodule
