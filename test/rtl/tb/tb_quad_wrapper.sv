`timescale 1ns/1ps
module tb_quad_wrapper;
`ifdef ACC_TILE_GATES
    localparam logic [63:0] FC_OUTPUT_INST = 64'h00000000_00000145;
`elsif GL_TEST
    localparam logic [63:0] FC_OUTPUT_INST = 64'h00003800_00000143;
`else
    localparam logic [63:0] FC_OUTPUT_INST = 64'h00000000_00000145;
`endif
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
`ifdef ACC_TILE_GATES
        .sck(uio_oe[3] && uio_out[3]), .cs_n(!uio_oe[6] || uio_out[6]),
`else
        .sck(uio_out[3]), .cs_n(uio_out[6]),
`endif
        .dq_out({uio_out[5:4],uio_out[2:1]}),
        .dq_oe({uio_oe[5:4],uio_oe[2:1]}), .dq_in(dq_in)
    );

`ifndef GL_TEST
    // Check the DMA link by counting accepted beats from each command length.
    // The monitor uses handshakes only, independent of either RTL counter.
    integer dma_beats_left;
    reg dma_write_pending, dma_check_write;
    `define ACCEL dut.core.accelerator
    always @(posedge clk) begin
        if (!rst_n) begin
            dma_beats_left = 0;
            dma_write_pending = 0;
            dma_check_write = 0;
        end else begin
            if (`ACCEL.dma_cmd_valid && `ACCEL.dma_cmd_ready) begin
                if (dma_beats_left != 0 || dma_write_pending)
                    $fatal(1,"DMA accepted a command before completing the previous one");
                dma_check_write = `ACCEL.dma_cmd_write;
                dma_write_pending = dma_check_write;
                dma_beats_left = int'(`ACCEL.dma_cmd_len) + 1;
            end
            if (`ACCEL.dma_write_data_valid && `ACCEL.dma_write_data_ready) begin
                if (!dma_check_write || dma_beats_left == 0)
                    $fatal(1,"Unexpected DMA write data");
                dma_beats_left = dma_beats_left - 1;
            end
            if (`ACCEL.dma_rsp_valid && `ACCEL.dma_rsp_ready) begin
                if (dma_check_write) begin
                    if (!dma_write_pending || dma_beats_left != 0)
                        $fatal(1,"DMA write completion arrived before all beats");
                    dma_write_pending = 0;
                end else begin
                    if (dma_beats_left == 0)
                        $fatal(1,"Unexpected DMA read data");
                    dma_beats_left = dma_beats_left - 1;
                end
            end
            if (done && (dma_beats_left != 0 || dma_write_pending))
                $fatal(1,"Unfinished DMA transaction at end of test");
        end
    end
    `undef ACCEL
`endif

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
        put('h200018, FC_OUTPUT_INST);
        put('h200020, 64'h00000000_000000ff); // synchronize
        put('h9000, 64'h00_00_3c_40_00_00_40_38);
        // At 1 Mbaud, also spill ACC, clobber it, reload it, then add a second product.
        if (header_divisor == 50) begin
            put('h200018, 64'h00009100_00000143); // store partial sum
            put('h200020, 64'h00009108_00000144); // clobber ACC
            put('h200028, 64'h00009100_00000144); // reload partial sum
            put('h200030, 64'h00000000_01000121); // accumulate another product
            put('h200038, FC_OUTPUT_INST);
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

`ifndef GL_TEST
    task automatic exchange_wb(input integer invalid_addr, input integer invalid_length);
        reg [7:0] low, high;
        rst_n = 0;
        clks_per_bit = 50;
        put('h1ffff8, 64'h202 | (64'd50 << 12));
        put('h1ff000, 64'h1ffff);
        put('h200000, 64'h00009000_00000140); // load UB row 0
        put('h200008, 64'h00009000_001f0140); // load UB row 31
        put('h200010, 64'h00000000_00000108); // select UB row 0
        put('h200018, 64'h00009008_001f0141); // load WB row 31
        put('h200020, 64'h00000000_3f000120); // multiply WB row 31
        // An invalid range must raise a fault without accumulating any rows.
        put('h200028, invalid_length == 0 ? 64'b0 :
            (64'(invalid_addr) << 24) | (64'(invalid_length) << 8) | 64'h21);
        put('h200030, FC_OUTPUT_INST);
        put('h200038, 64'h00000000_000000ff);
        put('h9000, 64'h00000000_00004038);
        put('h9008, 64'h00000000_00003c40);
        repeat(32) @(negedge clk);
        rst_n = 1;
        wait (uo[2] === 1'b1);
        repeat(8) @(negedge clk);
        fork
            begin send(8'h30); send(8'h38); end
            begin receive(low); receive(high); end
        join
        if ({high,low} !== 16'h4440 || uo[1] !== (invalid_length != 0))
            $fatal(1,"WB read: output %h, fault %b, invalid range %0d+%0d",
                   {high,low}, uo[1], invalid_addr, invalid_length);
        $display("QUAD_WRAPPER_WB_ADDRESS_PASS invalid_range=%0d+%0d", invalid_addr, invalid_length);
    endtask

    task automatic exchange_acc_uart;
        reg [7:0] value;
        reg [111:0] received;
        integer writes_before;
        rst_n = 0;
        clks_per_bit = 50;
        put('h1ffff8, 64'h202 | (64'd50 << 12));
        put('h1ff000, 64'h1ffff);
        put('h200000, 64'h00009200_00050244); // load ACC rows 5 and 6
        put('h200008, 64'h00003800_00050143); // ordinary PSRAM store at the former UART address
        put('h200010, 64'h00000000_00050245); // send two ACC rows
        put('h200018, 64'h00000012_00050145); // row 5, lanes 2–3
        put('h200020, 64'h00000009_00060145); // row 6, lane 1
        put('h200028, 64'h0000000b_00050145); // row 5, lanes 1–3
        put('h200030, 64'h0000001a_00050145); // invalid: lanes 3–4
        put('h200038, 64'h00000004_00060145); // row 6, all lanes
        put('h200040, 64'hff);
        put('h9200, 64'hc3d4_7856_a1b2_3412);
        put('h3800, 64'h6655_4433_2211_aa55);
        repeat(32) @(negedge clk);
        rst_n = 1;
        wait (uo[2] === 1'b1);
        repeat(8) @(negedge clk);
        writes_before = memory.writes;
        fork
            begin send(8'h00); send(8'h00); end
            begin
                for (integer i = 0; i < 14; i++) begin
                    receive(value);
                    received[8*i+:8] = value;
                    if (i == 1 && (dut.core.accelerator.complete_frames != 1 || uo[1] !== 1'b0))
                        $fatal(1,"The first ACC result should transmit before frame synchronization");
                end
            end
        join
        if (received !== 112'hc3d47856_a1b234_78_a1b2_78563412 || uo[1] !== 1'b1)
            $fatal(1,"ACC_TO_UART output %h fault %b", received, uo[1]);
        if ({memory.mem['h3803],memory.mem['h3802],memory.mem['h3801],memory.mem['h3800]}
            !== 32'ha1b2_3412 || memory.mem['h3804] !== 8'h33)
            $fatal(1,"ACC_TO_DRAM did not store precisely one row at 0x3800");
        if (memory.writes - writes_before != 2)
            $fatal(1,"Expected one input write and one ACC_TO_DRAM write");
        $display("QUAD_WRAPPER_ACC_TO_UART_PASS");
    endtask
`endif

    initial begin
        #1;
        exchange(0);
`ifndef GL_TEST
        exchange(50);
        exchange(434);
        exchange_wb(0, 0);
        exchange_wb(31, 2);
        exchange_wb(63, 2);
        exchange_wb(64, 1);
        exchange_acc_uart();

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
        repeat(45000) @(negedge clk);
        if (!done) $fatal(1,"Timeout waiting for UART/QPI exchange");
    end
endmodule
