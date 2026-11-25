// Send one to four 8N1 bytes, low byte first.
module uart_tx (
    input  logic        clk, rst_n,
    input  logic [9:0]  bit_last,
    input  logic        start,
    input  logic [31:0] data_in,
    input  logic [2:0]  byte_count,
    output logic        tx,
    output logic        idle
);
    logic [9:0] tx_frame;
    logic [23:0] pending_data;
    logic [3:0] frame_bits;
    logic [1:0] bytes_left;
    logic [9:0] tx_timer;

    assign idle = frame_bits == 0;
    assign tx = idle ? 1'b1 : tx_frame[0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_frame <= '1;
            pending_data <= '0;
            frame_bits <= '0;
            bytes_left <= '0;
            tx_timer <= '0;
        end else if (idle) begin
            if (start) begin
                tx_frame <= {1'b1, data_in[7:0], 1'b0};
                pending_data <= data_in[31:8];
                frame_bits <= 4'd10;
                bytes_left <= 2'(byte_count - 3'd1);
                tx_timer <= '0;
            end
        end else if (tx_timer == bit_last) begin
            tx_timer <= '0;
            if (frame_bits == 1 && bytes_left != 0) begin
                tx_frame <= {1'b1, pending_data[7:0], 1'b0};
                pending_data <= {8'b0, pending_data[23:8]};
                frame_bits <= 4'd10;
                bytes_left <= bytes_left - 1'b1;
            end else begin
                frame_bits <= frame_bits - 1'b1;
                tx_frame <= {1'b1, tx_frame[9:1]};
            end
        end else begin
            tx_timer <= tx_timer + 1'b1;
        end
    end
endmodule
