// SPI host bridge: staged instructions and independently backpressured AXI channels.
module acc_host (
    input wire clk, rst,
    input wire [5:0] address,
    input wire [7:0] write_data,
    input wire write_enable, action_enable,
    output reg [7:0] read_data,
    output wire [7:0] status
);
    reg [63:0] inst_stage, rdata_stage, rdata_pending;
    reg [6:0] rmeta_stage, rmeta_pending;
    reg [5:0] bmeta_stage, bmeta_pending;
    reg r_pending, b_pending, sync_seen, host_error;
    wire fifo_empty, fifo_full, synchronize, axi_error;
    wire [7:0] action = action_enable ? write_data : 8'b0;
    wire [4-1:0] m_axi_awid;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire  m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [2:0] m_axi_awprot;
    wire [3:0] m_axi_awqos;
    wire [3:0] m_axi_awregion;
    wire  m_axi_awvalid;
    wire  m_axi_awready;
    wire [64-1:0] m_axi_wdata;
    wire [8-1:0] m_axi_wstrb;
    wire  m_axi_wlast;
    wire  m_axi_wvalid;
    wire  m_axi_wready;
    wire [4-1:0] m_axi_bid;
    wire [1:0] m_axi_bresp;
    wire  m_axi_bvalid;
    wire  m_axi_bready;
    wire [4-1:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire  m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire [3:0] m_axi_arregion;
    wire  m_axi_arvalid;
    wire  m_axi_arready;
    wire [4-1:0] m_axi_rid;
    wire [64-1:0] m_axi_rdata;
    wire [1:0] m_axi_rresp;
    wire  m_axi_rlast;
    wire  m_axi_rvalid;
    wire  m_axi_rready;

    assign m_axi_awready = action[0];
    assign m_axi_wready  = action[1];
    assign m_axi_arready = action[2];
    assign m_axi_rdata = rdata_pending;
    assign m_axi_rid = rmeta_pending[3:0];
    assign m_axi_rresp = rmeta_pending[5:4];
    assign m_axi_rlast = rmeta_pending[6];
    assign m_axi_rvalid = r_pending;
    assign m_axi_bid = bmeta_pending[3:0];
    assign m_axi_bresp = bmeta_pending[5:4];
    assign m_axi_bvalid = b_pending;
    assign status = {host_error, axi_error, sync_seen, fifo_full, fifo_empty,
                     m_axi_arvalid, m_axi_wvalid, m_axi_awvalid};

    always @(posedge clk) begin
        if (rst) begin
            inst_stage <= 0; rdata_stage <= 0; rmeta_stage <= 0; bmeta_stage <= 0;
            rdata_pending <= 0; rmeta_pending <= 0; bmeta_pending <= 0;
            r_pending <= 0; b_pending <= 0; sync_seen <= 0; host_error <= 0;
        end else begin
            if (write_enable) begin
                if (address < 8) inst_stage[address[2:0]*8 +: 8] <= write_data;
                else if (address < 16) rdata_stage[address[2:0]*8 +: 8] <= write_data;
                else if (address == 16) rmeta_stage <= write_data[6:0];
                else if (address == 17) bmeta_stage <= write_data[5:0];
            end
            if (r_pending && m_axi_rready) r_pending <= 0;
            if (b_pending && m_axi_bready) b_pending <= 0;
            if (action[3] && !r_pending) begin
                rdata_pending <= rdata_stage; rmeta_pending <= rmeta_stage; r_pending <= 1;
            end
            if (action[4] && !b_pending) begin
                bmeta_pending <= bmeta_stage; b_pending <= 1;
            end
            if (action[6]) sync_seen <= 0;
            if (synchronize) sync_seen <= 1;
            if (action[7]) host_error <= 0;
            if ((action[3] && r_pending) || (action[4] && b_pending) ||
                (action[5] && fifo_full) || (action[0] && !m_axi_awvalid) ||
                (action[1] && !m_axi_wvalid) || (action[2] && !m_axi_arvalid)) host_error <= 1;
        end
    end

    always @* begin
        read_data = 0;
        case (address)
            0: read_data = status;
            1: read_data = {4'b0, m_axi_bready, m_axi_rready, b_pending, r_pending};
            2,3,4,5: read_data = m_axi_awaddr[(address-2)*8 +: 8];
            6: read_data = m_axi_awlen;
            7: read_data = {m_axi_awid, 1'b0, m_axi_awsize};
            8: read_data = {6'b0, m_axi_awburst};
            9,10,11,12: read_data = m_axi_araddr[(address-9)*8 +: 8];
            13: read_data = m_axi_arlen;
            14: read_data = {m_axi_arid, 1'b0, m_axi_arsize};
            15: read_data = {6'b0, m_axi_arburst};
            16,17,18,19,20,21,22,23: read_data = m_axi_wdata[address[2:0]*8 +: 8];
            24: read_data = m_axi_wstrb;
            25: read_data = {7'b0, m_axi_wlast};
            26: read_data = {m_axi_awcache, m_axi_awprot, m_axi_awlock};
            27: read_data = {m_axi_awregion, m_axi_awqos};
            28: read_data = {m_axi_arcache, m_axi_arprot, m_axi_arlock};
            29: read_data = {m_axi_arregion, m_axi_arqos};
            63: read_data = 8'hA1; // Protocol version / device ID
            default: read_data = 0;
        endcase
    end
    tpu accelerator (
        .clk(clk), .rst(rst), .inst_word(inst_stage),
        .inst_write_enable(action[5] && !fifo_full),
        .inst_fifo_empty(fifo_empty), .inst_fifo_full(fifo_full),
        .synchronize(synchronize), .axi_error(axi_error),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awregion(m_axi_awregion),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arregion(m_axi_arregion),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );
endmodule
