//Sparsity controller 
//
module sparsity_ctrl
    import tpu_pkg::*;
#(
    parameter int META_FIFO_DEPTH = 8,
    parameter int UB_ROWS = DEFAULT_SRAM_BYTES / 8
)(
    input logic clk,
    input logic rst, 

    // Instruction decoder -> sparsity_ctrl (input load inst)
    input  input_inst_type  input_inst,
    input  logic            input_inst_enable,

    // Controller status -> instruction decoder
    output logic            busy,
    output logic            resource_busy,

    // sparsity_ctrl -> vpu_ctrl
    output fp16_type        vpu_input_data,    
    output logic            vpu_input_valid,
    input  logic            vpu_input_ready,

    // weight_load_ctrl -> sparsity_ctrl
    input  logic            sparse_req_valid,
    output logic            sparse_req_ready,
    output logic            sparse_rsp_data,   // = mask_cs
    output logic            sparse_rsp_valid,

    // Address-only read request -> unified buffer
    output buffer_addr_type              input_read_req_addr, 
    output logic                         input_read_req_valid,
    input  logic                         input_read_req_ready,

    // Data-only read response <- unified buffer
    input  fp16_type                     input_read_rsp_data,
    input  logic                         input_read_rsp_valid,
    output logic                         input_read_rsp_ready,

    // Config
    input logic sparsity_en
);

    localparam int FIFO_PTR_WIDTH = 
        (META_FIFO_DEPTH > 1) ? $clog2(META_FIFO_DEPTH) : 1;

    typedef logic [FIFO_PTR_WIDTH-1:0]      fifo_ptr_t;
    
    function automatic fifo_ptr_t next_fifo_ptr(input fifo_ptr_t ptr);
        if(ptr == fifo_ptr_t'(META_FIFO_DEPTH - 1))
            next_fifo_ptr = '0;
        else
            next_fifo_ptr = ptr + 1'b1;
    endfunction

    // meta FIFO 
    localparam int UB_AW = $clog2(UB_ROWS);
    logic [UB_AW-1:0] addr_fifo [META_FIFO_DEPTH-1:0];
    logic invalid_addr_fifo [META_FIFO_DEPTH-1:0];
    fp16_type        val_fifo  [META_FIFO_DEPTH-1:0];

    fifo_ptr_t inst_ptr_cs;
    fifo_ptr_t req_ptr_cs;
    fifo_ptr_t rsp_ptr_cs;
    fifo_ptr_t vpu_ptr_cs;
    fifo_ptr_t mask_ptr_cs;

    logic push_fire;
    logic req_fire;
    logic rsp_fire;
    logic vpu_fire;
    logic serve_fire;

    assign busy = (next_fifo_ptr(inst_ptr_cs) == mask_ptr_cs) || (next_fifo_ptr(inst_ptr_cs) == vpu_ptr_cs);
    assign resource_busy = (mask_ptr_cs != inst_ptr_cs) || (vpu_ptr_cs != inst_ptr_cs);

    //step 1: push input load inst
    assign push_fire = input_inst_enable && !busy;

    //step 2: Unified buffer에 request
    assign input_read_req_valid = (req_ptr_cs != inst_ptr_cs);
    assign input_read_req_addr = invalid_addr_fifo[req_ptr_cs] ? '1 : buffer_addr_type'(addr_fifo[req_ptr_cs]);
    assign req_fire = input_read_req_valid && input_read_req_ready;

    //step 3
    assign input_read_rsp_ready = (rsp_ptr_cs != req_ptr_cs);
    assign rsp_fire = input_read_rsp_valid && input_read_rsp_ready;

    //step 4-1
    assign vpu_input_valid = (vpu_ptr_cs != rsp_ptr_cs);
    assign vpu_input_data = val_fifo[vpu_ptr_cs];
    assign vpu_fire = vpu_input_ready && vpu_input_valid;

    //step 4-2
    assign sparse_req_ready = (mask_ptr_cs != rsp_ptr_cs);
    assign sparse_rsp_valid = sparse_req_valid && sparse_req_ready;
    assign sparse_rsp_data = sparsity_en ? (val_fifo[mask_ptr_cs] != '0) : 1'b1;
    assign serve_fire = sparse_rsp_valid;

    always_ff @(posedge clk) begin
        if(rst) begin
            inst_ptr_cs <= '0;
            req_ptr_cs <= '0;
            rsp_ptr_cs <= '0;
            vpu_ptr_cs <= '0;
            mask_ptr_cs <= '0;
        end
        else begin
            if (push_fire) begin
                addr_fifo[inst_ptr_cs] <= UB_AW'(input_inst.input_addr);
                invalid_addr_fifo[inst_ptr_cs] <= input_inst.input_addr >= UB_ROWS;
                inst_ptr_cs <= next_fifo_ptr(inst_ptr_cs);
            end

            if (req_fire) 
                req_ptr_cs <= next_fifo_ptr(req_ptr_cs);

            if (rsp_fire) begin
                val_fifo[rsp_ptr_cs] <= input_read_rsp_data;
                rsp_ptr_cs <= next_fifo_ptr(rsp_ptr_cs);
            end

            if (vpu_fire) 
                vpu_ptr_cs <= next_fifo_ptr(vpu_ptr_cs);
                
            if (serve_fire) 
                mask_ptr_cs <= next_fifo_ptr(mask_ptr_cs);
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (META_FIFO_DEPTH < 2)
            $fatal(1, "sparsity_ctrl META_FIFO_DEPTH must be at least two");
    end
`endif
    
endmodule