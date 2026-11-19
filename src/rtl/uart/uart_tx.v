`include "defs/defs.vh"
// Wire-protocol bytes stay 8 bits independently of the compute format.

module uart_tx #(
    parameter integer CLKS_PER_BIT = 87 // for 115200 baud, 10MHz clk
) (
    input  wire clk,
    input  wire rst_n,

    input  wire inst_fifo_rdy,

    output wire tx
);

    localparam integer TIMER_BITS = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    localparam [TIMER_BITS-1:0] BIT_LAST = TIMER_BITS'(CLKS_PER_BIT - 1);

    reg [TIMER_BITS-1:0] clk_cnt;
    reg [$clog2(8+2)-1:0] bit_idx;

    localparam IDLE = 0;
    localparam DATA = 1;

    reg state;
    reg ready_sent; // Send once per HIGH request; a LOW cycle re-arms TX.

    // The only frame is READY (0x01): start=0, bit 0=1, bits 1..7=0, stop=1.
    // Decode the two HIGH positions instead of storing a constant frame.
    assign tx = (state != DATA) || (bit_idx == 1) || (bit_idx == 8+1);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            clk_cnt <= 0;
            bit_idx <= 0;
            ready_sent <= 0;
        end
        else begin
            if (!inst_fifo_rdy)
                ready_sent <= 0;

            case(state)
                IDLE: begin
                    if (inst_fifo_rdy && !ready_sent) begin
                        ready_sent <= 1'b1;
                        bit_idx <= 0;
                        state <= DATA;
                    end
                end
                DATA: begin
                    if (clk_cnt == BIT_LAST) begin
                        clk_cnt <= 0;
                        if (bit_idx == 8+1) begin
                            state <= IDLE;
                        end
                        else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end
                    else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                default: begin end
            endcase
        end
    end

endmodule
