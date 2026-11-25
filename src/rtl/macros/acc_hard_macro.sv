module acc_hard_macro (
    input wire clk, rst_n, uart_rx_i,
    input wire [3:0] qspi_dq_i,
    output wire [7:0] uo_out, uio_out, uio_oe
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync;
    wire core_rst_n = reset_sync[1];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_sync <= 0;
        else reset_sync <= {reset_sync[0],1'b1};
    end

    wire tx, sck, cs_n, fault, ready;
    wire [3:0] dq_out, dq_oe;
    accelerator_top #(.INGRESS_BYTES(2)) accelerator (
        .clk(clk), .rst_n(core_rst_n), .rx(uart_rx_i), .dq_in(qspi_dq_i),
        .dq_out(dq_out), .dq_oe(dq_oe), .tx(tx), .sck(sck), .cs_n(cs_n),
        .fault(fault), .ready(ready)
    );

    // Same TinyQV QSPI Pmod pin order as the previous macro.
    assign uio_out = {1'b1,cs_n,dq_out[3:2],sck,dq_out[1:0],1'b1};
    assign uio_oe = core_rst_n && rst_n ? {2'b11,dq_oe[3:2],1'b1,dq_oe[1:0],1'b1} : 8'b0;
    assign uo_out = {3'b0,tx,1'b0,ready,fault,1'b0};
endmodule
