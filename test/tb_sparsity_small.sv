`timescale 1ns/1ps
module tb_sparsity_small;
    import tpu_pkg::*;
    parameter int DEPTH=2;
    logic clk=0,rst=1,en=0,busy,resource_busy,vvalid,vready=0;
    logic mvalid=0,mready,mask,mrsp,reqvalid,reqready=0,rspvalid=0,rspready,sparsity_en=1;
    input_inst_type inst;
    fp16_type value,rspdata;
    buffer_addr_type addr;
    buffer_addr_type expected_addr[512];
    fp16_type expected_data[512];
    integer pushed=0,requested=0,responded=0,consumed=0,masks=0,full_cycles=0;
    sparsity_ctrl #(.META_FIFO_DEPTH(DEPTH),.UB_ROWS(64)) dut(
        .clk(clk),.rst(rst),.input_inst(inst),.input_inst_enable(en),
        .busy(busy),.resource_busy(resource_busy),.vpu_input_data(value),
        .vpu_input_valid(vvalid),.vpu_input_ready(vready),
        .sparse_req_valid(mvalid),.sparse_req_ready(mready),
        .sparse_rsp_data(mask),.sparse_rsp_valid(mrsp),
        .input_read_req_addr(addr),.input_read_req_valid(reqvalid),.input_read_req_ready(reqready),
        .input_read_rsp_data(rspdata),.input_read_rsp_valid(rspvalid),.input_read_rsp_ready(rspready),
        .sparsity_en(sparsity_en));
    always #5 clk=~clk;
    initial begin
        inst='0;rspdata=0;
        repeat(2) @(negedge clk);rst=0;
        for(int cycle=0;cycle<10000;cycle++) begin
            en=pushed<512 && cycle%5!=0;
            inst.input_addr=16'(pushed%80);
            reqready=cycle%7!=0;
            rspvalid=responded<requested && cycle%3!=0;
            rspdata=rspvalid ? expected_data[responded] : 0;
            vready=cycle>100 && cycle%4!=0;
            mvalid=cycle>150 && cycle%6!=0;
            sparsity_en=cycle%11!=0;
            #1;
            if(busy) full_cycles++;
            if(en && !busy) begin
                expected_addr[pushed]=pushed%80<64 ? 16'(pushed%80) : 16'hffff;
                expected_data[pushed]=pushed%3==0 ? 0 : 16'(16'h3c00+pushed);
                pushed++;
            end
            if(reqvalid && reqready) begin
                if(requested>=pushed || addr!==expected_addr[requested]) $fatal(1,"request order/address");
                requested++;
            end
            if(rspvalid && rspready) responded++;
            if(vvalid && vready) begin
                if(consumed>=responded || value!==expected_data[consumed]) $fatal(1,"VPU data/order");
                consumed++;
            end
            if(mrsp) begin
                if(masks>=responded || mask!==(sparsity_en ? expected_data[masks]!=0 : 1'b1)) $fatal(1,"mask data/order");
                masks++;
            end
            if(pushed-consumed>DEPTH-1 || pushed-masks>DEPTH-1) $fatal(1,"FIFO overcommitted");
            @(negedge clk);
        end
        if(pushed!=512 || consumed!=512 || masks!=512 || resource_busy || full_cycles==0)
            $fatal(1,"failed to drain or never exercised full FIFO");
        $display("PASS: 512 sparse entries, FIFO full/wrap, independent stalls and invalid addresses");
        $finish;
    end
endmodule
