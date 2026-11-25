// Receive two 8N1 bytes and assemble them into a little-endian word.
module uart_rx (
    input  wire clk,
    input  wire rst_n,

    output reg [15:0] data_out,
    output reg data_valid,
    output reg error,

    input  wire [9:0] bit_last, half_bit_last,
    input  wire rx
);

    localparam integer BYTE_COUNT = $bits(data_out) / 8;
    localparam integer BYTE_IDX_BITS = BYTE_COUNT > 1 ? $clog2(BYTE_COUNT) : 1;
    localparam [BYTE_IDX_BITS-1:0] BYTE_LAST = BYTE_IDX_BITS'(BYTE_COUNT - 1);

    reg rx_meta;
    reg rx_sync;

    reg [BYTE_IDX_BITS-1:0] byte_idx;
    reg [9:0] clk_cnt;
    reg [$clog2(8+2)-1:0] bit_idx;

    reg [1:0] state;

    localparam RESET = 2'd0;
    localparam IDLE  = 2'd1;
    localparam DATA  = 2'd2;

    always @(posedge clk) begin
        if (!rst_n) begin
            data_valid <= 0;
            error <= 0;
            data_out <= 0;
            rx_meta <= 0;
            rx_sync <= 0;
            clk_cnt <= 0;
            bit_idx <= 0;
            byte_idx <= 0;
            state <= RESET;
        end
        else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;

            case (state)
                RESET: begin
                    data_valid <= 0;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    data_out <= 0;
                    byte_idx <= 0;

                    if (rx_sync == 1) begin
                        state <= IDLE;
                    end
                end
                IDLE : begin
                    data_valid <= 0;
                    if (rx_sync == 0) begin
                        bit_idx <= 0;
                        state <= DATA;
                    end
                end
                DATA : begin
                    if (bit_idx == 0) begin
                        if (clk_cnt == half_bit_last) begin
                            clk_cnt <= 0;

                            if (!rx_sync)
                                bit_idx <= bit_idx + 1;
                            else
                                // if it was just noise..
                                state <= IDLE;
                        end
                        else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                    else begin
                        if (clk_cnt == bit_last) begin
                            clk_cnt <= 0;

                            if (bit_idx <= 8) begin
                                // LSB-first bits and low-byte-first words end up
                                // in natural order after both bytes.
                                data_out <= {rx_sync, data_out[15:1]};

                                bit_idx <= bit_idx + 1;
                            end
                            else begin
                                if (rx_sync) begin
                                    if (byte_idx == BYTE_LAST) begin
                                        data_valid <= 1;
                                        byte_idx <= 0;
                                    end else begin
                                        byte_idx <= byte_idx + 1'b1;
                                    end

                                    state <= IDLE;
                                end
                                else begin
                                    // Framing failure invalidates the current host frame until reset.
                                    error <= 1;
                                    state <= RESET;
                                end
                            end
                        end
                        else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end
                default: state <= RESET;
            endcase
        end
    end

endmodule
