
`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// rdo_filter_axi_slave_lite_v1_0_S00_AXI.v
//
// MODIFIED from the Vivado wizard-generated template. Delta:
//   1) Added user ports:
//        outputs -- ctrl_reg, lambda, r_none, r_pc, r_ns  (exposes writable regs)
//        inputs  -- status_word, sel_none_lo/hi, sel_pc_lo/hi, sel_ns_lo/hi
//                  (drive READ path for RO status registers 5..11)
//   2) Removed the wizard's default S_AXI_RDATA giant-ternary
//      and replaced it with a mux that returns the status inputs for the
//      RO regs and the stored slv_regs for the R/W regs.
//   3) Added output assigns that expose slv_reg0..4 to the user logic.
//
// Everything else is verbatim from the wizard.
// -----------------------------------------------------------------------------

    module rdo_filter_axi_slave_lite_v1_0_S00_AXI #
    (
        // User parameters
        // (none)
        // Wizard parameters:
        parameter integer C_S_AXI_DATA_WIDTH    = 32,
        parameter integer C_S_AXI_ADDR_WIDTH    = 6
    )
    (
        // ----- USER PORTS BEGIN -----
        // Exposed writable registers (driven from stored slv_regs)
        output wire [31:0] ctrl_reg,     // slv_reg0
        output wire [15:0] lambda,       // slv_reg1[15:0]
        output wire [15:0] r_none,       // slv_reg2[15:0]
        output wire [15:0] r_pc,         // slv_reg3[15:0]
        output wire [15:0] r_ns,         // slv_reg4[15:0]

        // Consumed status inputs (drive READ mux for RO regs)
        input  wire [31:0] status_word,      // slv_reg5 readback  (num_ru, ru_idx, starvation)
        input  wire [31:0] sel_none_lo_in,   // slv_reg6
        input  wire [31:0] sel_none_hi_in,   // slv_reg7
        input  wire [31:0] sel_pc_lo_in,     // slv_reg8
        input  wire [31:0] sel_pc_hi_in,     // slv_reg9
        input  wire [31:0] sel_ns_lo_in,     // slv_reg10
        input  wire [31:0] sel_ns_hi_in,     // slv_reg11
        // ----- USER PORTS END -----

        input wire  S_AXI_ACLK,
        input wire  S_AXI_ARESETN,
        input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
        input wire [2 : 0] S_AXI_AWPROT,
        input wire  S_AXI_AWVALID,
        output wire  S_AXI_AWREADY,
        input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
        input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
        input wire  S_AXI_WVALID,
        output wire  S_AXI_WREADY,
        output wire [1 : 0] S_AXI_BRESP,
        output wire  S_AXI_BVALID,
        input wire  S_AXI_BREADY,
        input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
        input wire [2 : 0] S_AXI_ARPROT,
        input wire  S_AXI_ARVALID,
        output wire  S_AXI_ARREADY,
        output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
        output wire [1 : 0] S_AXI_RRESP,
        output wire  S_AXI_RVALID,
        input wire  S_AXI_RREADY
    );

    // AXI4LITE signals
    reg [C_S_AXI_ADDR_WIDTH-1 : 0]  axi_awaddr;
    reg     axi_awready;
    reg     axi_wready;
    reg [1 : 0]     axi_bresp;
    reg     axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0]  axi_araddr;
    reg     axi_arready;
    reg [1 : 0]     axi_rresp;
    reg     axi_rvalid;

    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 3;

    // 12 slave registers (wizard-generated storage; writes always land here,
    // reads for R/W regs come from here, reads for RO regs come from user inputs).
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg0;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg1;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg2;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg3;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg4;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg5;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg6;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg7;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg8;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg9;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg10;
    reg [C_S_AXI_DATA_WIDTH-1:0]    slv_reg11;
    integer  byte_index;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    reg [1:0] state_write;
    reg [1:0] state_read;
    localparam Idle = 2'b00, Raddr = 2'b10, Rdata = 2'b11, Waddr = 2'b10, Wdata = 2'b11;

    // ========================================================================
    // Write state machine (verbatim from wizard)
    // ========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_awready <= 0;
            axi_wready  <= 0;
            axi_bvalid  <= 0;
            axi_bresp   <= 0;
            axi_awaddr  <= 0;
            state_write <= Idle;
        end else begin
            case (state_write)
                Idle: begin
                    if (S_AXI_ARESETN == 1'b1) begin
                        axi_awready <= 1'b1;
                        axi_wready  <= 1'b1;
                        state_write <= Waddr;
                    end else state_write <= state_write;
                end
                Waddr: begin
                    if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                        axi_awaddr <= S_AXI_AWADDR;
                        if (S_AXI_WVALID) begin
                            axi_awready <= 1'b1;
                            state_write <= Waddr;
                            axi_bvalid  <= 1'b1;
                        end else begin
                            axi_awready <= 1'b0;
                            state_write <= Wdata;
                            if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                        end
                    end else begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
                Wdata: begin
                    if (S_AXI_WVALID) begin
                        state_write <= Waddr;
                        axi_bvalid  <= 1'b1;
                        axi_awready <= 1'b1;
                    end else begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid) axi_bvalid <= 1'b0;
                    end
                end
            endcase
        end
    end

    // ========================================================================
    // Register write logic (verbatim from wizard)
    // ========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            slv_reg0  <= 0; slv_reg1  <= 0; slv_reg2 <= 0; slv_reg3 <= 0;
            slv_reg4  <= 0; slv_reg5  <= 0; slv_reg6 <= 0; slv_reg7 <= 0;
            slv_reg8  <= 0; slv_reg9  <= 0; slv_reg10 <= 0; slv_reg11 <= 0;
        end else if (S_AXI_WVALID) begin
            case ((S_AXI_AWVALID) ? S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB]
                                  : axi_awaddr [ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
                4'h0: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg0[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h1: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg1[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h2: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg2[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h3: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg3[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h4: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg4[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                // Writes to RO regs (5..11) still land in slv_reg5..11 but are ignored
                // by the read mux below. This preserves wizard structure without breaking anything.
                4'h5: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg5[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h6: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg6[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h7: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg7[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h8: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg8[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'h9: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg9[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'hA: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg10[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                4'hB: for (byte_index=0; byte_index<=(C_S_AXI_DATA_WIDTH/8)-1; byte_index=byte_index+1)
                        if (S_AXI_WSTRB[byte_index]) slv_reg11[(byte_index*8)+:8] <= S_AXI_WDATA[(byte_index*8)+:8];
                default: begin
                    slv_reg0<=slv_reg0; slv_reg1<=slv_reg1; slv_reg2<=slv_reg2;
                    slv_reg3<=slv_reg3; slv_reg4<=slv_reg4; slv_reg5<=slv_reg5;
                    slv_reg6<=slv_reg6; slv_reg7<=slv_reg7; slv_reg8<=slv_reg8;
                    slv_reg9<=slv_reg9; slv_reg10<=slv_reg10; slv_reg11<=slv_reg11;
                end
            endcase
        end
    end

    // ========================================================================
    // Read state machine (verbatim from wizard)
    // ========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 1'b0;
            state_read  <= Idle;
        end else begin
            case (state_read)
                Idle: begin
                    if (S_AXI_ARESETN == 1'b1) begin
                        state_read  <= Raddr;
                        axi_arready <= 1'b1;
                    end else state_read <= state_read;
                end
                Raddr: begin
                    if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                        state_read  <= Rdata;
                        axi_araddr  <= S_AXI_ARADDR;
                        axi_rvalid  <= 1'b1;
                        axi_arready <= 1'b0;
                    end else state_read <= state_read;
                end
                Rdata: begin
                    if (S_AXI_RVALID && S_AXI_RREADY) begin
                        axi_rvalid  <= 1'b0;
                        axi_arready <= 1'b1;
                        state_read  <= Raddr;
                    end else state_read <= state_read;
                end
            endcase
        end
    end

    // ========================================================================
    // MODIFIED read mux -- RO regs (5..11) return the user-supplied inputs
    // rather than whatever the PS wrote into slv_reg5..11.
    // ========================================================================
    wire [3:0] rd_addr = axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

    assign S_AXI_RDATA =
        (rd_addr == 4'h0) ? slv_reg0        :
        (rd_addr == 4'h1) ? slv_reg1        :
        (rd_addr == 4'h2) ? slv_reg2        :
        (rd_addr == 4'h3) ? slv_reg3        :
        (rd_addr == 4'h4) ? slv_reg4        :
        (rd_addr == 4'h5) ? status_word     :
        (rd_addr == 4'h6) ? sel_none_lo_in  :
        (rd_addr == 4'h7) ? sel_none_hi_in  :
        (rd_addr == 4'h8) ? sel_pc_lo_in    :
        (rd_addr == 4'h9) ? sel_pc_hi_in    :
        (rd_addr == 4'hA) ? sel_ns_lo_in    :
        (rd_addr == 4'hB) ? sel_ns_hi_in    :
        32'h0;

    // ========================================================================
    // Expose writable regs to user logic
    // ========================================================================
    assign ctrl_reg = slv_reg0;
    assign lambda   = slv_reg1[15:0];
    assign r_none   = slv_reg2[15:0];
    assign r_pc     = slv_reg3[15:0];
    assign r_ns     = slv_reg4[15:0];

    endmodule
