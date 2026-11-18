`include "defs/defs.vh"
// Wire-protocol bytes stay 8 bits independently of FP16 compute width.

// Protocol reference: TinyQV TT06 cpu/qspi_ctrl.v, commit
// dfbd5e3882442c07e4627bfb5f627ba7bff00baf (Michael Bell).
// Uses its QPI PSRAM commands, shared CS selection and shift-register approach.
// This is an adaptation, not the silicon-tested TinyQV RTL: Flash programming
// and single-byte request/response handling are our own additions.
//
// One 8-bit request at a time. Mode 0, SCK = clk / 2.
// req_addr must remain stable from acceptance until read_data_val.
// req_write/req_data are captured on acceptance and may change afterward.
// Board setup: PSRAMs in QPI; Flash in SPI with QE=1, not continuous read.
// Flash program targets must already be erased/unprotected. No erase interface.
// Separate device select: 00=Flash, 10=PSRAM A, 11=PSRAM B.
// One data byte per request; every byte address is supported.
// Status polling has no timeout/error port: failed WREN or permanent busy waits.
// Reset aborts the bus transaction; it cannot undo a memory write already made.
module qspi_ctrl (
    input  wire clk,
    input  wire rst_n,

    input  wire req_val,
    output wire req_rdy,
    input  wire req_write,
    input  wire [23:0] req_addr,
    input  wire [1:0] req_device,
    input  wire [8-1:0] req_data,

    // Valid after read completion and until the next request is accepted.
    // During a transfer, this exposes the shared shift register (not valid data).
    output wire [8-1:0] read_data,
    output reg read_data_val,

    output reg sck,
    output reg flash_sc_n,
    output reg psram_a_sc_n,
    output reg psram_b_sc_n,
    input  wire [3:0] dq_in,
    output reg [3:0] dq_out,
    output reg [3:0] dq_oe
);

    localparam [3:0]
        IDLE = 0, SELECT = 1, CMD = 2, ADDR = 3,
        DUMMY = 4, DATA = 5, STATUS = 6, DESELECT = 7,
        CHECK = 8;

    // Each Flash operation may require several separate CS transactions.
    localparam [2:0]
        MEMORY = 0, WAIT_READY = 1, WRITE_ENABLE = 2,
        CHECK_ENABLE = 3, WAIT_PROGRAM = 4;

    reg [3:0] state;
    reg [2:0] operation;
    reg [1:0] chip;
    reg write_reg;
    reg [8-1:0] data_shift;
    reg [1:0] status_shift; // Keep only the last two status bits: WEL and WIP.
    reg [4:0] cycles_left;

    // Reuse the serial byte register as the read result.
    assign read_data = data_shift;
    wire is_ram = chip[1];
    wire [7:0] memory_opcode = is_ram
        ? (write_reg ? 8'h02 : 8'h0b)
        : (write_reg ? 8'h32 : 8'h6b);

    // The parent holds the address; select its next bit/nibble directly.
    // PSRAM uses 23 address bits and a leading zero in its 24-bit header.
    wire [23:0] address = is_ram ? {1'b0, req_addr[22:0]} : req_addr[23:0];
    // Select a nibble once; SPI then selects one bit inside that nibble.
    wire [2:0] address_nibble_index = is_ram ? cycles_left[2:0] : cycles_left[4:2];
    wire [3:0] address_nibble = address[{address_nibble_index, 2'b00} +: 4];
    wire [7:0] command = operation == MEMORY ? memory_opcode :
        (operation == WRITE_ENABLE ? 8'h06 : 8'h05);

    // Single-byte transfers accept both even and odd addresses.
    assign req_rdy = rst_n && state == IDLE;

    // SPI headers/status keep Flash WP_n and HOLD_n high.
    // QPI headers and payloads use all four pins. Reads release the bus.
    always @(*) begin
        dq_out = 4'b1100;
        dq_oe = 4'b0000;

        case (state)
            CMD: begin
                if (is_ram) begin
                    dq_out = cycles_left[0] ? command[7:4] : command[3:0];
                    dq_oe = 4'b1111;
                end else begin
                    dq_out[0] = command[cycles_left[2:0]];
                    dq_oe = 4'b1101;
                end
            end
            ADDR: begin
                if (is_ram) begin
                    dq_out = address_nibble;
                    dq_oe = 4'b1111;
                end else begin
                    dq_out[0] = address_nibble[cycles_left[1:0]];
                    dq_oe = 4'b1101;
                end
            end
            DATA: begin
                if (write_reg) begin
                    dq_out = data_shift[8-1 -: 4];
                    dq_oe = 4'b1111;
                end
            end
            STATUS: dq_oe = 4'b1101; // Status returned on IO1.
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            operation <= MEMORY;
            chip <= 0;
            write_reg <= 0;
            data_shift <= 0;
            status_shift <= 0;
            cycles_left <= 0;
            read_data_val <= 0;
            sck <= 0;
            flash_sc_n <= 1;
            psram_a_sc_n <= 1;
            psram_b_sc_n <= 1;
        end else begin
            read_data_val <= 0;

            case (state)
                IDLE: begin
                    if (req_val && req_rdy) begin
                        chip <= req_device;
                        write_reg <= req_write;
                        // Most significant nibble first.
                        data_shift <= req_data;
                        operation <= req_device[1] ? MEMORY : WAIT_READY;
                        state <= SELECT;
                    end
                end

                SELECT: begin
                    flash_sc_n <= is_ram;
                    psram_a_sc_n <= chip != 2'b10;
                    psram_b_sc_n <= chip != 2'b11;
                    sck <= 0;

                    cycles_left <= is_ram ? 1 : 7;
                    state <= CMD;
                end

                CMD, ADDR, DUMMY, DATA, STATUS: begin
                    // Mode 0: sample inputs on rising SCK; change outputs
                    // on falling SCK. Each half-cycle is one core clock.
                    sck <= !sck;
                    if (!sck) begin
                        if (state == DATA && !write_reg)
                            data_shift <= {data_shift[8-5:0], dq_in};
                        if (state == STATUS)
                            status_shift <= {status_shift[0], dq_in[1]};
                    end else begin
                        if (cycles_left != 0) begin
                            cycles_left <= cycles_left - 1'b1;
                            case (state)
                                DATA: if (write_reg)
                                    data_shift <= {data_shift[8-5:0], 4'b0};
                                default: begin end
                            endcase
                        end else begin
                            case (state)
                                CMD: begin
                                    if (operation == MEMORY) begin
                                        cycles_left <= is_ram ? 5 : 23;
                                        state <= ADDR;
                                    end else if (operation == WRITE_ENABLE) begin
                                        state <= DESELECT;
                                    end else begin
                                        cycles_left <= 7;
                                        state <= STATUS;
                                    end
                                end
                                ADDR: begin
                                    if (write_reg) begin
                                        cycles_left <= 1;
                                        state <= DATA;
                                    end else begin
                                        cycles_left <= is_ram ? 3 : 7;
                                        state <= DUMMY;
                                    end
                                end
                                DUMMY: begin
                                    cycles_left <= 1;
                                    state <= DATA;
                                end
                                DATA: begin
                                    state <= DESELECT;
                                end
                                STATUS: state <= DESELECT;
                                default: state <= DESELECT;
                            endcase
                        end
                    end
                end

                DESELECT: begin
                    // One core clock of hold time after the final falling SCK.
                    flash_sc_n <= 1;
                    psram_a_sc_n <= 1;
                    psram_b_sc_n <= 1;
                    state <= CHECK;
                end

                // CS has been high for one core clock on entry.
                // A following SELECT occurs one clock later (200 ns at 10 MHz).
                CHECK: begin
                    case (operation)
                        MEMORY: begin
                            if (!is_ram && write_reg) begin
                                operation <= WAIT_PROGRAM;
                                state <= SELECT;
                            end else begin
                                read_data_val <= 1;
                                state <= IDLE;
                            end
                        end
                        WAIT_READY: begin
                            if (!status_shift[0])
                                operation <= write_reg ? WRITE_ENABLE : MEMORY;
                            state <= SELECT;
                        end
                        WRITE_ENABLE: begin
                            operation <= CHECK_ENABLE;
                            state <= SELECT;
                        end
                        CHECK_ENABLE: begin
                            if (!status_shift[0] && status_shift[1])
                                operation <= MEMORY;
                            else
                                operation <= WAIT_READY;
                            state <= SELECT;
                        end
                        WAIT_PROGRAM: begin
                            if (status_shift[0])
                                state <= SELECT;
                            else begin
                                read_data_val <= 1;
                                state <= IDLE;
                            end
                        end
                        default: state <= IDLE;
                    endcase
                end

                default: begin
                    state <= IDLE;
                    sck <= 0;
                    flash_sc_n <= 1;
                    psram_a_sc_n <= 1;
                    psram_b_sc_n <= 1;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    // Check the borrowed-address contract in standalone and integration tests.
    reg [23:0] accepted_addr;
    always @(posedge clk) begin
        if (!rst_n)
            accepted_addr <= 0;
        else if (req_val && req_rdy) begin
            accepted_addr <= req_addr;
            if (req_device == 2'b01)
                $fatal(1, "Reserved memory device selector");
            if (req_device[1] && req_addr[23])
                $fatal(1, "PSRAM byte address must fit in 23 bits");
        end
        else if (state != IDLE && req_addr !== accepted_addr)
            $fatal(1, "qspi_ctrl req_addr changed before completion");
    end

`endif
endmodule
