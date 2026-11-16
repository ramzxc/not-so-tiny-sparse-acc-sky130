// Mode 0, MSB first, two bytes per CS assertion: command, payload.
// Command: 00aaaaaa read, 01aaaaaa write, 10000000 action.
// SCK <= clk/8; CS high/low setup >= 4 clk cycles. All logic uses clk.
module acc_spi (
    input wire clk, rst,
    input wire sck, cs_n, mosi,
    output reg miso,
    output reg [5:0] address,
    output reg [7:0] write_data,
    output reg write_enable, action_enable,
    input wire [7:0] read_data
);
    reg [2:0] sck_sync, cs_sync;
    reg [1:0] mosi_sync;
    reg [7:0] rx, tx;
    reg [2:0] bit_count;
    reg [1:0] operation;
    localparam COMMAND=0, LOAD=1, PAYLOAD=2, DONE=3;
    reg [1:0] state;
    wire rising_sck = sck_sync[1] && !sck_sync[2];
    wire falling_sck = !sck_sync[1] && sck_sync[2];
    wire [7:0] received = {rx[6:0], mosi_sync[1]};
    always @(posedge clk) begin
        if (rst) begin
            sck_sync <= 0; cs_sync <= 3'b111; mosi_sync <= 0;
            rx <= 0; tx <= 0; bit_count <= 0; state <= COMMAND;
            operation <= 0; address <= 0; write_data <= 0;
            write_enable <= 0; action_enable <= 0; miso <= 0;
        end else begin
            sck_sync <= {sck_sync[1:0], sck};
            cs_sync <= {cs_sync[1:0], cs_n};
            mosi_sync <= {mosi_sync[0], mosi};
            write_enable <= 0;
            action_enable <= 0;
            if (cs_sync[2]) begin
                state <= COMMAND; bit_count <= 0; rx <= 0; miso <= 0;
            end else begin
                if (state == LOAD) begin
                    tx <= read_data;
                    state <= PAYLOAD;
                end
                if (falling_sck)
                    miso <= (state == PAYLOAD && operation == 0) ? tx[7-bit_count] : 1'b0;
                if (rising_sck && (state == COMMAND || state == PAYLOAD)) begin
                    rx <= received;
                    bit_count <= bit_count + 1'b1;
                    if (bit_count == 7) begin
                        if (state == COMMAND) begin
                            address <= received[5:0];
                            operation <= received[7:6];
                            state <= LOAD;
                        end else begin
                            write_data <= received;
                            write_enable <= operation == 1;
                            action_enable <= operation == 2 && address == 0;
                            state <= DONE;
                        end
                    end
                end
            end
        end
    end
endmodule
