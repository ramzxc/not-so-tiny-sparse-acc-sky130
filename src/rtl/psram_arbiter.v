// Whole-transaction ownership: data has priority at each idle boundary.
// Requesters hold their request until ready. Completion goes only to its owner.
module psram_arbiter #(parameter integer FETCH_WRITES=0) (
    input wire clk,rst_n,
    input wire data_valid,data_write,
    input wire [22:0] data_addr,
    input wire [3:0] data_bytes,
    input wire [15:0] data_wdata,
    output wire data_ready,data_done,data_byte_valid,
    input wire fetch_valid,fetch_write,
    input wire [15:0] fetch_wdata,
    input wire [22:0] fetch_addr,
    input wire [3:0] fetch_bytes,
    output wire fetch_ready,fetch_done,fetch_byte_valid,
    output wire req_valid,req_write,
    output wire [22:0] req_addr,
    output wire [3:0] req_bytes,
    output wire [15:0] req_data,
    input wire req_ready,done,byte_valid,
    output reg busy
);
    reg owner_fetch;
    assign req_valid=rst_n && !busy && (data_valid || fetch_valid);
    wire select_data=busy ? !owner_fetch : data_valid;
    assign req_write=select_data ? data_write : (FETCH_WRITES!=0 && fetch_write);
    assign req_addr=select_data ? data_addr : fetch_addr;
    assign req_bytes=select_data ? data_bytes : fetch_bytes;
    assign req_data=(FETCH_WRITES!=0 && !select_data) ? fetch_wdata : data_wdata;
    assign data_ready=rst_n && !busy && req_ready;
    assign fetch_ready=rst_n && !busy && !data_valid && req_ready;
    assign data_byte_valid=busy && !owner_fetch && byte_valid;
    assign fetch_byte_valid=busy && owner_fetch && byte_valid;
    assign data_done=busy && !owner_fetch && done;
    assign fetch_done=busy && owner_fetch && done;
    always @(posedge clk) begin
        if(!rst_n)begin busy<=0;owner_fetch<=0;end
        else begin
            if(req_valid && req_ready)begin busy<=1;owner_fetch<=!data_valid;end
            if(busy && done)busy<=0;
        end
    end
endmodule
