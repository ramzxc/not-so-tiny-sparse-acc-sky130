`timescale 1ns/1ps
module tb_quad_wrapper;
    integer clks_per_bit = 87;
    reg clk = 0, rst_n = 0, rx = 1;
    reg done = 0;
    always #10 clk = ~clk;
    wire [7:0] uo, uio_out, uio_oe;
    wire [3:0] dq_in;
    wire [7:0] uio_in = {2'b11, dq_in[3:2], 1'b0, dq_in[1:0], 1'b1};

    supply1 VPWR;
    supply0 VGND;
    tt_um_not_so_tiny_sparse_acc_ramzxc dut (
`ifdef USE_POWER_PINS
        .VPWR(VPWR), .VGND(VGND),
`endif
        .ui_in({4'b0,rx,3'b0}), .uo_out(uo), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );
    qspi_psram_model #(.DEPTH(23'h200100)) memory (
        .sck(uio_out[3]), .cs_n(uio_out[6]),
        .dq_out({uio_out[5:4],uio_out[2:1]}),
        .dq_oe({uio_oe[5:4],uio_oe[2:1]}), .dq_in(dq_in)
    );

    task automatic put(input integer address, input [63:0] word);
        for (integer i = 0; i < 8; i++) memory.mem[address+i] = word[8*i+:8];
    endtask

    task automatic send(input [7:0] value);
        rx = 0;
        repeat(clks_per_bit) @(negedge clk);
        for (integer bit_index = 0; bit_index < 8; bit_index++) begin
            rx = value[bit_index];
            repeat(clks_per_bit) @(negedge clk);
        end
        rx = 1;
        repeat(clks_per_bit) @(negedge clk);
    endtask

    task automatic receive(output reg [7:0] value);
        @(negedge uo[4]);
        repeat(clks_per_bit + clks_per_bit/2) @(negedge clk);
        for (integer bit_index = 0; bit_index < 8; bit_index++) begin
            value[bit_index] = uo[4];
            repeat(clks_per_bit) @(negedge clk);
        end
        if (uo[4] !== 1'b1) $fatal(1,"UART stop bit");
    endtask

    task automatic exchange(input integer header_divisor);
        reg [7:0] low, high;
        rst_n = 0;
        clks_per_bit = header_divisor == 0 ? 87 : header_divisor;
        put('h1ffff8, 64'h202 | (64'(header_divisor) << 12)); // batch 1, two channels
        put('h1ff000, 64'h1ffff);        // no repeated blocks
        put('h200000, 64'h00009000_00000240); // load 2 UB rows
        put('h200008, 64'h00000000_00000108); // select UB row 0
        put('h200010, 64'h00000000_01000120); // multiply UB row 1
        put('h200018, 64'h00003800_00000143); // send ACC row 0 to FC destination
        put('h200020, 64'h00000000_000000ff); // synchronize
        put('h9000, 64'h00_00_3c_40_00_00_40_38);
        // At 1 Mbaud, also spill ACC, clobber it, reload it, then add a second product.
        if (header_divisor == 50) begin
            put('h200018, 64'h00009100_00000143); // store partial sum
            put('h200020, 64'h00009108_00000144); // clobber ACC
            put('h200028, 64'h00009100_00000144); // reload partial sum
            put('h200030, 64'h00000000_01000121); // accumulate another product
            put('h200038, 64'h00003800_00000143);
            put('h200040, 64'h00000000_000000ff);
            put('h9108, 0);
        end
        repeat(32) @(negedge clk);
        rst_n = 1;
        wait (uo[2] === 1'b1);
        repeat(8) @(negedge clk);
        fork
            begin send(8'h30); send(8'h38); end
            begin receive(low); receive(high); end
        join
        if ({high,low} !== (header_divisor == 50 ? 16'h4c48 : 16'h4440) || uo[1] !== 1'b0)
            $fatal(1,"FC output %h, fault bit %b", {high,low}, uo[1]);
        if (header_divisor == 50 && {memory.mem['h9101],memory.mem['h9100]} !== 16'h4440)
            $fatal(1,"ACC partial sum did not reach PSRAM");
        if ({memory.mem['h8001],memory.mem['h8000]} !== 16'h3830)
            $fatal(1,"UART input did not reach PSRAM");
        $display("QUAD_WRAPPER_UART_QPI_PASS clocks_per_bit=%0d", clks_per_bit);
    endtask

    initial begin
        #1;
        exchange(0);
`ifndef GL_TEST
        exchange(50);
        exchange(434);

        rst_n = 0;
        put('h1ffff8, 64'h202 | (64'd31 << 12));
        repeat(32) @(negedge clk);
        rst_n = 1;
        repeat(200) @(negedge clk);
        if (uo[2] !== 1'b0 || uo[1] !== 1'b1)
            $fatal(1,"Unsupported UART divisor did not raise the boot fault");
`endif
        done = 1;
`ifndef COCOTB_SIM
        $finish;
`endif
    end
    initial begin
        repeat(35000) @(negedge clk);
        if (!done) $fatal(1,"Timeout waiting for UART/QPI exchange");
    end
endmodule
