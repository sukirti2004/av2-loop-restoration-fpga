`timescale 1 ns / 1 ps

module ns_filter_slave_lite_v1_0_S00_AXI #
(
    parameter integer C_S_AXI_DATA_WIDTH    = 32,
    // Kept at 6 (16 words, 64-byte range) to match the packaged IP-XACT.
    // Status reads alias low addresses (see wrapper) — no addr-width bump needed.
    parameter integer C_S_AXI_ADDR_WIDTH    = 6
)
(
    // ---- Write-side signals exposed to external register bank ----
    output wire        reg_wr_en,
    output wire  [5:0] reg_wr_addr,
    output wire [31:0] reg_wr_data,

    // ---- Read-side signals exposed to external status mux ----
    // reg_rd_addr is the current AXI-Lite read address (word index).
    // reg_rd_data is combinationally driven by the wrapper based on reg_rd_addr.
    output wire  [5:0] reg_rd_addr,
    input  wire [31:0] reg_rd_data,

    input  wire S_AXI_ACLK,
    input  wire S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input  wire [2 : 0] S_AXI_AWPROT,
    input  wire  S_AXI_AWVALID,
    output wire  S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input  wire  S_AXI_WVALID,
    output wire  S_AXI_WREADY,
    output wire [1 : 0] S_AXI_BRESP,
    output wire  S_AXI_BVALID,
    input  wire  S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input  wire [2 : 0] S_AXI_ARPROT,
    input  wire  S_AXI_ARVALID,
    output wire  S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output wire [1 : 0] S_AXI_RRESP,
    output wire  S_AXI_RVALID,
    input  wire  S_AXI_RREADY
);

    reg [C_S_AXI_ADDR_WIDTH-1 : 0]  axi_awaddr;
    reg                             axi_awready;
    reg                             axi_wready;
    reg [1 : 0]                     axi_bresp;
    reg                             axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0]  axi_araddr;
    reg                             axi_arready;
    reg [1 : 0]                     axi_rresp;
    reg                             axi_rvalid;

    // Byte-in-word bits + word-index bits.
    // ADDR_LSB=2 (32-bit words), OPT_MEM_ADDR_BITS bumped 3->4 for 32 words.
    localparam integer ADDR_LSB          = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 3;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // Read data comes back from wrapper mux.
    assign S_AXI_RDATA = reg_rd_data;

    // ---- Write-side plumbing (unchanged apart from wider address slice) ----
    assign reg_wr_en   = S_AXI_WVALID && axi_wready;
    assign reg_wr_addr = {{(6-(OPT_MEM_ADDR_BITS+1)){1'b0}},
                          S_AXI_AWVALID ? S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]
                                        : axi_awaddr [ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]};
    assign reg_wr_data = S_AXI_WDATA;

    // ---- Read-side address decode (mirror of write side) ----
    assign reg_rd_addr = {{(6-(OPT_MEM_ADDR_BITS+1)){1'b0}},
                          S_AXI_ARVALID ? S_AXI_ARADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]
                                        : axi_araddr [ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]};

    reg [1:0] state_write;
    reg [1:0] state_read;

    localparam Idle  = 2'b00,
               Raddr = 2'b10,
               Rdata = 2'b11,
               Waddr = 2'b10,
               Wdata = 2'b11;

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_awready <= 0;
            axi_wready  <= 0;
            axi_bvalid  <= 0;
            axi_bresp   <= 0;
            axi_awaddr  <= 0;
            state_write <= Idle;
        end
        else begin
            case (state_write)
                Idle: begin
                    if (S_AXI_ARESETN == 1'b1) begin
                        axi_awready <= 1'b1;
                        axi_wready  <= 1'b1;
                        state_write <= Waddr;
                    end
                    else state_write <= state_write;
                end
                Waddr: begin
                    if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                        axi_awaddr <= S_AXI_AWADDR;
                        if (S_AXI_WVALID) begin
                            axi_awready <= 1'b1;
                            state_write <= Waddr;
                            axi_bvalid  <= 1'b1;
                        end
                        else begin
                            axi_awready <= 1'b0;
                            state_write <= Wdata;
                            if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                        end
                    end
                    else begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
                Wdata: begin
                    if (S_AXI_WVALID) begin
                        state_write <= Waddr;
                        axi_bvalid  <= 1'b1;
                        axi_awready <= 1'b1;
                    end
                    else begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
            endcase
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 1'b0;
            state_read  <= Idle;
        end
        else begin
            case (state_read)
                Idle: begin
                    if (S_AXI_ARESETN == 1'b1) begin
                        state_read  <= Raddr;
                        axi_arready <= 1'b1;
                    end
                    else state_read <= state_read;
                end
                Raddr: begin
                    if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                        state_read  <= Rdata;
                        axi_araddr  <= S_AXI_ARADDR;
                        axi_rvalid  <= 1'b1;
                        axi_arready <= 1'b0;
                    end
                    else state_read <= state_read;
                end
                Rdata: begin
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        axi_rvalid  <= 1'b0;
                        axi_arready <= 1'b1;
                        state_read  <= Raddr;
                    end
                    else state_read <= state_read;
                end
            endcase
        end
    end

endmodule
