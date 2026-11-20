`timescale 1ns/1ps
module tb_psram_stream #(parameter integer UART_CLKS_PER_BIT=8, parameter integer QUEUE_SLOT_BITS=14);
    logic clk,rst_n,ena;
    logic [7:0] ui_in;
    wire [7:0] uo_out,uio_out,uio_oe;
    wire [3:0] dq;
    acc_hard_macro #(.UART_CLKS_PER_BIT(UART_CLKS_PER_BIT),.QUEUE_SLOT_BITS(QUEUE_SLOT_BITS)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx_i(ui_in[3]),.qspi_dq_i(dq),
        .uo_out(uo_out),.uio_out(uio_out),.uio_oe(uio_oe));
    defparam dut.itf.memory.size_1k.macro.VERBOSE=0;
    qspi_psram_model psram_model (
        .sck(uio_oe[3] ? uio_out[3] : 1'b0),.cs_n(uio_oe[6] ? uio_out[6] : 1'b1),
        .dq_out({uio_out[5:4],uio_out[2:1]}),.dq_oe({uio_oe[5:4],uio_oe[2:1]}),.dq_in(dq));
    wire [QUEUE_SLOT_BITS:0] queue_count=dut.ingress.queued;
    wire [QUEUE_SLOT_BITS-1:0] queue_write_slot=dut.ingress.write_slot;
    wire queue_pending=dut.ingress.pending;
    logic [31:0] completed=0;
    logic [31:0] ingress_wait=0,ingress_wait_max=0;
    always @(posedge clk)begin
        if(!rst_n)begin ingress_wait<=0;ingress_wait_max<=0;end
        else if(queue_pending && queue_count < (1<<QUEUE_SLOT_BITS))begin
            ingress_wait<=ingress_wait+1;
            if(ingress_wait+1>ingress_wait_max)ingress_wait_max<=ingress_wait+1;
        end else ingress_wait<=0;
    end
    always @(posedge clk)begin
        if(!rst_n)completed<=0;
        else if(dut.command.frontend.state==10 && dut.command.frontend.units_idle)completed<=completed+1;
    end
    logic [22:0] observe_addr;
    wire [15:0] observe_data={psram_model.mem[observe_addr+1],psram_model.mem[observe_addr]};
    wire [8191:0] sram_snapshot;
    for(genvar r=0;r<128;r++)assign sram_snapshot[64*r+:64]=dut.itf.memory.size_1k.macro.mem[r][63:0];
    wire [31:0] reads=psram_model.reads,writes=psram_model.writes;
    logic [31:0] collisions=0,fetches=0,data_wait_fetch=0,fetch_wait_data=0;
    always @(posedge clk)if(rst_n)begin
        if(dut.qspi_req_val && dut.fetch_valid)collisions<=collisions+1;
        if(dut.qspi_req_val && dut.bus_busy && dut.psram.memory_owner.owner_fetch)data_wait_fetch<=data_wait_fetch+1;
        if(dut.fetch_valid && dut.bus_busy && !dut.psram.memory_owner.owner_fetch)fetch_wait_data<=fetch_wait_data+1;
        if(dut.fetch_valid && dut.fetch_ready)fetches<=fetches+1;
        if(dut.qspi_done && dut.fetch_done)$fatal(1,"double completion");
        if(uio_out[0]!==1 || uio_out[7]!==1)$fatal(1,"unused memories selected");
    end
    string fixture;
    initial begin
        #1;
        if(!$value$plusargs("FIXTURE=%s",fixture))$fatal(1,"missing PSRAM image");
        $readmemh(fixture,psram_model.mem);
    end
endmodule
