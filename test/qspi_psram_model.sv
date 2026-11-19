`timescale 1ns/1ps
// Independent pin-level APS6404L QPI functional model (board-prepared mode).
// Checks protocol, bus direction and refresh-related CS timing, not signoff timing.
module qspi_psram_model #(
    parameter int DEPTH = 8388608,
    parameter time MAX_CS_LOW = 8000ns
)(
    input logic sck, cs_n,
    input logic [3:0] dq_out, dq_oe,
    output logic [3:0] dq_in
);
    logic [7:0] mem [0:DEPTH-1];
    logic [7:0] opcode, byte_data;
    logic [23:0] addr;
    integer phase = 0, nibbles = 0, dummy = 0, index = 0;
    integer reads = 0, writes = 0;
    time selected_at = 0, deselected_at = 0;
    time max_active = 0;

    initial begin
        dq_in = 4'hf;
        for (int a = 0; a < DEPTH; a++) mem[a] = 'x;
    end

    always @(negedge cs_n) begin
        if (deselected_at != 0 && $time - deselected_at < 18ns)
            $fatal(1, "PSRAM CS-high recovery too short");
        selected_at = $time;
        phase = 0;
        nibbles = 0;
        opcode = 0;
        addr = 0;
        dq_in = 4'hf;
    end

    always @(posedge sck) if (!cs_n) begin
        case (phase)
            0: begin
                if (dq_oe !== 4'hf) $fatal(1, "PSRAM command must use QPI");
                opcode = {opcode[3:0], dq_out};
                nibbles++;
                if (nibbles == 2) begin
                    if (opcode != 8'h0b && opcode != 8'h02)
                        $fatal(1, "Unexpected PSRAM opcode %h", opcode);
                    phase = 1;
                    nibbles = 0;
                end
            end
            1: begin
                if (dq_oe !== 4'hf) $fatal(1, "PSRAM address must use QPI");
                addr = {addr[19:0], dq_out};
                nibbles++;
                if (nibbles == 6) begin
                    if (int'(addr) >= DEPTH) $fatal(1, "PSRAM model address out of range");
                    index = int'(addr);
                    nibbles = 0;
                    if (opcode == 8'h0b) begin
                        phase = 2;
                        dummy = 0;
                        reads++;
                    end else begin
                        phase = 4;
                        writes++;
                    end
                end
            end
            2: begin
                if (dq_oe !== 0) $fatal(1, "PSRAM read dummy bus not released");
                dummy++;
                if (dummy == 4) begin phase = 3; nibbles = 0; end
            end
            3: begin
                if (dq_oe !== 0) $fatal(1, "PSRAM read bus contention");
                nibbles++;
                if (nibbles == 2) begin index++; nibbles = 0; end
            end
            4: begin
                if (dq_oe !== 4'hf) $fatal(1, "PSRAM write bus not driven");
                byte_data = {byte_data[3:0], dq_out};
                nibbles++;
                if (nibbles == 2) begin
                    if (index >= DEPTH) $fatal(1, "PSRAM write outside model");
                    mem[index] = byte_data;
                    index++;
                    nibbles = 0;
                end
            end
        endcase
    end

    always @(negedge sck) if (!cs_n) begin
        dq_in = 4'hf;
        if (phase == 3 && index < DEPTH)
            dq_in = nibbles == 0 ? mem[index][7:4] : mem[index][3:0];
    end

    always @(posedge cs_n) begin
        dq_in = 4'hf;
        deselected_at = $time;
        if (selected_at != 0) begin
            if ($time - selected_at > max_active) max_active = $time - selected_at;
            if ($time - selected_at > MAX_CS_LOW) $fatal(1, "PSRAM tCEM exceeds tCEM");
        end
    end
endmodule
