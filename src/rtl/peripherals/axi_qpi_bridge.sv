// Original TPU adapter. Keep AXI bursts independent of QPI read chunks.
module axi_qpi_bridge #(
    parameter int INGRESS_BYTES = 8,
    parameter bit LOCAL_FC_OUTPUT = 1'b0
) (
    input wire clk, rst_n,
    input wire [31:0] araddr, awaddr,
    input wire [7:0] arlen, awlen,
    input wire [3:0] arid, awid,
    input wire arvalid, awvalid,
    output wire arready, awready,
    input wire [63:0] wdata,
    input wire [7:0] wstrb,
    input wire wlast, wvalid,
    output wire wready,
    output wire [63:0] rdata,
    output wire [3:0] rid, bid,
    output wire rlast, rvalid, bvalid,
    input wire rready, bready,
    input wire input_valid,
    input wire [22:0] input_addr,
    input wire [8*INGRESS_BYTES-1:0] input_data,
    output wire input_ready, input_done,
    input wire fetch_req, fetch_take, fetch_pair,
    input wire [22:0] fetch_addr,
    input wire [2:0] fetch_words,
    output wire fetch_valid,
    output wire [63:0] fetch_data,
    output wire sck, cs_n,
    input wire [3:0] dq_in,
    output wire [3:0] dq_out, dq_oe
);
    localparam [2:0] IDLE=0, READ_REQ=1, READ_WAIT=2, WRITE_BEAT=3,
        WRITE_REQ=4, WRITE_WAIT=5, WRITE_RESPONSE=6, LOCAL_WRITE_BEAT=7;
    localparam [31:0] FC_OUTPUT_ADDR = 32'h00003800;
    reg [2:0] state;
    reg [3:0] tag;
    reg [63:0] beat;
    reg [63:0] instruction;
    reg instruction_pending;
    reg [2:0] fetch_length;
    wire [7:0] fetch_page_beats = 8'd128-{1'b0,fetch_addr[9:3]};
    reg [22:0] addr;
    reg [7:0] remaining;
    reg [2:0] byte_index;
    reg fetching, pair_fetching, scalar_alias, broadcast_lane;
    reg [3:0] write_bytes;
    reg pending, chunk_done, last_sent, input_write;
    wire [7:0] byte_data;
    wire byte_valid, done, ready;
    wire issue = state==READ_REQ || state==WRITE_REQ;
    wire [2:0] last_byte = fetching && pair_fetching ? 3'd1 :
                           !fetching && scalar_alias ? 3'd0 : 3'd7;
    wire complete_beat = byte_valid && byte_index==last_byte;
    wire r_fire = rvalid && rready;
    wire stalled = rvalid && !rready;
    // End the physical chunk if the consumer blocks. Retain the assembled
    // beat until AXI takes it, then issue another header at the next address.
    wire read_hold = state==READ_WAIT && complete_beat;
    // A prefetched instruction can outlive its QPI transaction so a stalled
    // instruction FIFO can never block an AXI transfer needed to drain it.
    wire fetch_cut = fetching && instruction_pending &&
                     (!fetch_take || arvalid || awvalid);
    wire read_cut = state==READ_WAIT && (stalled || fetch_cut);

    // Split ordinary reads at 64 bytes and at the next PSRAM page. The alias
    // and instruction paths are single reads; their existing format is kept.
    wire [3:0] requested_beats = remaining>=7 ? 4'd8 : {1'b0,remaining[2:0]}+4'd1;
    wire [7:0] page_beats = 8'd128-{1'b0,addr[9:3]};
    wire [3:0] burst_beats = page_beats<{4'b0,requested_beats} ?
                             page_beats[3:0] : requested_beats;
    wire [6:0] transfer_bytes = state==WRITE_REQ ? {3'b0,write_bytes} :
                                (fetching ? (pair_fetching ? 7'd2 : {1'b0,fetch_length,3'b0}) : scalar_alias ? 7'd1 : {burst_beats,3'b0});

    assign input_ready=rst_n && state==IDLE;
    assign input_done=state==WRITE_WAIT && input_write && done;
    assign arready=input_ready && !input_valid;
    assign awready=arready && !arvalid;
    assign wready=state==WRITE_BEAT || state==LOCAL_WRITE_BEAT;
    assign rvalid=state==READ_WAIT && !fetching && pending;
    assign bvalid=state==WRITE_RESPONSE;
    assign rlast=remaining==0;
    assign rdata=beat;
    assign rid=tag;
    assign bid=tag;
    assign fetch_valid=instruction_pending;
    assign fetch_data=instruction;

    qpi_burst_engine serial_memory (
        .clk(clk), .rst_n(rst_n), .req_valid(issue), .req_ready(ready),
        .req_write(state==WRITE_REQ), .req_addr(addr), .req_bytes(transfer_bytes),
        .req_data(beat), .read_hold(read_hold), .read_cut(read_cut),
        .read_data(byte_data), .byte_valid(byte_valid), .done(done),
        .sck(sck), .cs_n(cs_n), .dq_in(dq_in), .dq_out(dq_out), .dq_oe(dq_oe)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=IDLE; tag<=0; beat<=0; addr<=0; remaining<=0; byte_index<=0;
            fetching<=0; pair_fetching<=0; scalar_alias<=0; broadcast_lane<=0; write_bytes<=0;
            pending<=0; chunk_done<=0; last_sent<=0; input_write<=0;
            instruction<=0; instruction_pending<=0; fetch_length<=0;
        end else begin
            if(fetch_take)instruction_pending<=0;
            case(state)
                IDLE: if(input_valid) begin
                    addr<=input_addr;
                    beat<=64'(input_data);
                    write_bytes<=4'(INGRESS_BYTES);
                    input_write<=1;
                    state<=WRITE_REQ;
                end else if(arvalid) begin
                    addr<=araddr[22] ? {4'b0,araddr[21:3]} : araddr[22:0];
                    remaining<=arlen; tag<=arid; fetching<=0;
                    scalar_alias<=araddr[22]; broadcast_lane<=araddr[23];
                    last_sent<=0; state<=READ_REQ;
                end else if(awvalid) begin
                    addr<=awaddr[22:0]; remaining<=awlen; tag<=awid;
                    if(LOCAL_FC_OUTPUT && awaddr==FC_OUTPUT_ADDR && awlen==0)
                        state<=LOCAL_WRITE_BEAT;
                    else state<=WRITE_BEAT;
                end else if(fetch_req && !instruction_pending) begin
                    addr<=fetch_addr; fetching<=1; pair_fetching<=fetch_pair; broadcast_lane<=0;
                    fetch_length<=fetch_page_beats<{5'b0,fetch_words} ?
                                  fetch_page_beats[2:0] : fetch_words;
                    state<=READ_REQ;
                end

                READ_REQ: if(ready) begin
                    byte_index<=0;
                    pending<=0;
                    chunk_done<=0;
                    state<=READ_WAIT;
                end
                READ_WAIT: begin
                    if(byte_valid) begin
                        beat[8*byte_index+:8]<=byte_data;
                        byte_index<=byte_index+1'b1;
                        if(complete_beat) begin
                            if(fetching)begin
                                instruction<=pair_fetching ? {48'b0,byte_data,beat[7:0]} :
                                             {byte_data,beat[55:0]};
                                byte_index<=0;
                                instruction_pending<=1;
                            end else begin
                                if (scalar_alias) begin
                                    beat<={32'b0,broadcast_lane ? {3{byte_data}} : 24'b0,byte_data};
                                    byte_index<=0;
                                end else if(broadcast_lane) beat[31:8]<={3{beat[7:0]}};
                                pending<=1;
                            end
                        end
                    end
                    if(r_fire) begin
                        pending<=0;
                        if(rlast)last_sent<=1;
                        else begin
                            remaining<=remaining-1'b1;
                            addr<=addr+23'd8;
                        end
                    end
                    if(done)chunk_done<=1;
                    if((chunk_done || done) && !byte_valid) begin
                        if(fetching)state<=IDLE;
                        else if(!pending || r_fire) begin
                            if(last_sent || (r_fire && rlast))state<=IDLE;
                            else state<=READ_REQ;
                        end
                    end
                end

                // uart_stream captures the result on the same AXI W handshake.
                // Keep the normal B response and skip the QPI write states.
                LOCAL_WRITE_BEAT: if(wvalid)state<=WRITE_RESPONSE;
                WRITE_BEAT: if(wvalid) begin
                    beat<=wdata;
                    case(wstrb)
                        8'h03: write_bytes<=2;
                        8'h0f: write_bytes<=4;
                        8'h3f: write_bytes<=6;
                        default: write_bytes<=8;
                    endcase
                    state<=WRITE_REQ;
                end
                WRITE_REQ: if(ready)state<=WRITE_WAIT;
                WRITE_WAIT: if(done) begin
                    if(input_write) begin
                        input_write<=0;
                        state<=IDLE;
                    end else if(remaining==0)state<=WRITE_RESPONSE;
                    else begin
                        addr<=addr+23'd8; remaining<=remaining-1'b1; state<=WRITE_BEAT;
                    end
                end
                WRITE_RESPONSE: if(bready)state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if(rst_n) begin
        if(arvalid && arready) begin
            if(araddr[2:0]!=0)$fatal(1,"AXI read address must be beat-aligned");
            if(araddr[22] && arlen!=0)$fatal(1,"scalar view requires one beat");
        end
        if(wvalid && wready) begin
            if(wstrb!=8'hff && wstrb!=8'h3f && wstrb!=8'h0f && wstrb!=8'h03)$fatal(1,"unexpected write strobe");
            if(wlast!=(remaining==0))$fatal(1,"unexpected write last");
        end
        if(byte_valid && pending)$fatal(1,"PSRAM overwrote a pending AXI beat");
        if(fetching && complete_beat && instruction_pending && !fetch_take)
            $fatal(1,"PSRAM overwrote a pending instruction");
        if(state==IDLE && !input_valid && !arvalid && !awvalid && fetch_req && !instruction_pending &&
           (fetch_words==0 || fetch_words>4 ||
            (fetch_pair ? (fetch_words!=1 || fetch_addr[0]!=0) : fetch_addr[2:0]!=0)))
            $fatal(1,"invalid instruction batch");
        if(done && state==READ_WAIT && byte_index!=0)$fatal(1,"incomplete 8B beat");
    end
`endif
endmodule
