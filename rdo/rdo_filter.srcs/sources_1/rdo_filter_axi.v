`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// rdo_filter_axi.v
//
// MODIFIED from the Vivado wizard-generated top-level. Delta:
//   1) Removed the 4 wizard-generated stream slave *_inst instantiations
//      (they were demo modules with internal 8-word FIFOs -- not useful).
//   2) Added connections between the AXI-Lite slave's exposed regs, the
//      new stream_sync module (combines the 4 AXI-Stream inputs), and
//      rdo_top (the algorithm module).
//   3) Same-clock architecture: s00_axi_aclk == s0X_axis_aclk (tied in BD).
//      Reset is active-low S_AXI_ARESETN, inverted for internal use.
//
// Assumes external axis_data_fifo blocks (in the BD) sit between each
// upstream DMA and this IP's s0X_axis_* ports. See stream_sync.v header.
// -----------------------------------------------------------------------------

    module rdo_filter_axi #
    (
        // Wizard parameters (unchanged)
        parameter integer C_S00_AXI_DATA_WIDTH   = 32,
        parameter integer C_S00_AXI_ADDR_WIDTH   = 6,
        parameter integer C_S00_AXIS_TDATA_WIDTH = 32,
        parameter integer C_S01_AXIS_TDATA_WIDTH = 32,
        parameter integer C_S02_AXIS_TDATA_WIDTH = 32,
        parameter integer C_S03_AXIS_TDATA_WIDTH = 32,

        // User parameters (RDO combiner sizing)
        parameter integer RU_SIZE_LOG2 = 8,   // RU_SIZE = 256
        parameter integer RU_IDX_W     = 6,
        parameter integer NUM_RU       = 64,
        parameter integer WR_IDX_W     = 6,
        parameter integer HR_DELAY     = 0
    )
    (
        // AXI-Lite slave (config regs)
        input wire  s00_axi_aclk,
        input wire  s00_axi_aresetn,
        input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
        input wire [2 : 0] s00_axi_awprot,
        input wire  s00_axi_awvalid,
        output wire  s00_axi_awready,
        input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
        input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
        input wire  s00_axi_wvalid,
        output wire  s00_axi_wready,
        output wire [1 : 0] s00_axi_bresp,
        output wire  s00_axi_bvalid,
        input wire  s00_axi_bready,
        input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
        input wire [2 : 0] s00_axi_arprot,
        input wire  s00_axi_arvalid,
        output wire  s00_axi_arready,
        output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
        output wire [1 : 0] s00_axi_rresp,
        output wire  s00_axi_rvalid,
        input wire  s00_axi_rready,

        // AXI-Stream slave S00: HR reference
        input wire  s00_axis_aclk,
        input wire  s00_axis_aresetn,
        output wire  s00_axis_tready,
        input wire [C_S00_AXIS_TDATA_WIDTH-1 : 0] s00_axis_tdata,
        input wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
        input wire  s00_axis_tlast,
        input wire  s00_axis_tvalid,

        // AXI-Stream slave S01: NONE candidate (SR image)
        input wire  s01_axis_aclk,
        input wire  s01_axis_aresetn,
        output wire  s01_axis_tready,
        input wire [C_S01_AXIS_TDATA_WIDTH-1 : 0] s01_axis_tdata,
        input wire [(C_S01_AXIS_TDATA_WIDTH/8)-1 : 0] s01_axis_tstrb,
        input wire  s01_axis_tlast,
        input wire  s01_axis_tvalid,

        // AXI-Stream slave S02: PC candidate
        input wire  s02_axis_aclk,
        input wire  s02_axis_aresetn,
        output wire  s02_axis_tready,
        input wire [C_S02_AXIS_TDATA_WIDTH-1 : 0] s02_axis_tdata,
        input wire [(C_S02_AXIS_TDATA_WIDTH/8)-1 : 0] s02_axis_tstrb,
        input wire  s02_axis_tlast,
        input wire  s02_axis_tvalid,

        // AXI-Stream slave S03: NS candidate
        input wire  s03_axis_aclk,
        input wire  s03_axis_aresetn,
        output wire  s03_axis_tready,
        input wire [C_S03_AXIS_TDATA_WIDTH-1 : 0] s03_axis_tdata,
        input wire [(C_S03_AXIS_TDATA_WIDTH/8)-1 : 0] s03_axis_tstrb,
        input wire  s03_axis_tlast,
        input wire  s03_axis_tvalid
    );

    // Same-clock convention: all aclk pins are tied to the same net in the BD.
    // Use s00_axi_aclk as the master; s00_axis_aresetn is redundant.
    wire clk = s00_axi_aclk;
    wire rst = ~s00_axi_aresetn;   // internal modules use active-high

    // =========================================================================
    // AXI-Lite slave (writable regs exposed, RO regs driven by status inputs)
    // =========================================================================
    wire [31:0] ctrl_reg;
    wire [15:0] lambda;
    wire [15:0] r_none, r_pc, r_ns;

    wire [31:0] status_word;
    wire [31:0] sel_none_lo, sel_none_hi;
    wire [31:0] sel_pc_lo,   sel_pc_hi;
    wire [31:0] sel_ns_lo,   sel_ns_hi;

    rdo_filter_axi_slave_lite_v1_0_S00_AXI # (
        .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
    ) rdo_filter_axi_slave_lite_v1_0_S00_AXI_inst (
        // Wizard-generated AXI signals
        .S_AXI_ACLK    (s00_axi_aclk),
        .S_AXI_ARESETN (s00_axi_aresetn),
        .S_AXI_AWADDR  (s00_axi_awaddr),
        .S_AXI_AWPROT  (s00_axi_awprot),
        .S_AXI_AWVALID (s00_axi_awvalid),
        .S_AXI_AWREADY (s00_axi_awready),
        .S_AXI_WDATA   (s00_axi_wdata),
        .S_AXI_WSTRB   (s00_axi_wstrb),
        .S_AXI_WVALID  (s00_axi_wvalid),
        .S_AXI_WREADY  (s00_axi_wready),
        .S_AXI_BRESP   (s00_axi_bresp),
        .S_AXI_BVALID  (s00_axi_bvalid),
        .S_AXI_BREADY  (s00_axi_bready),
        .S_AXI_ARADDR  (s00_axi_araddr),
        .S_AXI_ARPROT  (s00_axi_arprot),
        .S_AXI_ARVALID (s00_axi_arvalid),
        .S_AXI_ARREADY (s00_axi_arready),
        .S_AXI_RDATA   (s00_axi_rdata),
        .S_AXI_RRESP   (s00_axi_rresp),
        .S_AXI_RVALID  (s00_axi_rvalid),
        .S_AXI_RREADY  (s00_axi_rready),
        // Exposed writable regs
        .ctrl_reg      (ctrl_reg),
        .lambda        (lambda),
        .r_none        (r_none),
        .r_pc          (r_pc),
        .r_ns          (r_ns),
        // RO status inputs
        .status_word   (status_word),
        .sel_none_lo_in(sel_none_lo),
        .sel_none_hi_in(sel_none_hi),
        .sel_pc_lo_in  (sel_pc_lo),
        .sel_pc_hi_in  (sel_pc_hi),
        .sel_ns_lo_in  (sel_ns_lo),
        .sel_ns_hi_in  (sel_ns_hi)
    );

    // CTRL bit layout:
    //   ctrl_reg[0] = clear (level, PS pulses high-then-low)
    //   ctrl_reg[2] = sof_pulse (level; falls to PS to clear)
    wire clear     = ctrl_reg[0];
    wire sof       = ctrl_reg[2];

    // =========================================================================
    // Stream synchronizer -- combines 4 lock-step streams from BD FIFOs
    // =========================================================================
    wire        valid_in;
    wire [7:0]  hr_px, none_px, pc_px, ns_px;
    wire [15:0] starvation_ctr;

    stream_sync u_stream_sync (
        .clk            (clk),
        .rst            (rst),

        .s_hr_tvalid    (s00_axis_tvalid),
        .s_hr_tready    (s00_axis_tready),
        .s_hr_tdata     (s00_axis_tdata),

        .s_none_tvalid  (s01_axis_tvalid),
        .s_none_tready  (s01_axis_tready),
        .s_none_tdata   (s01_axis_tdata),

        .s_pc_tvalid    (s02_axis_tvalid),
        .s_pc_tready    (s02_axis_tready),
        .s_pc_tdata     (s02_axis_tdata),

        .s_ns_tvalid    (s03_axis_tvalid),
        .s_ns_tready    (s03_axis_tready),
        .s_ns_tdata     (s03_axis_tdata),

        .valid_in       (valid_in),
        .hr_px          (hr_px),
        .none_px        (none_px),
        .pc_px          (pc_px),
        .ns_px          (ns_px),

        .starvation_ctr (starvation_ctr)
    );

    // =========================================================================
    // RDO algorithm module
    // =========================================================================
    wire [NUM_RU-1:0]    sel_none, sel_pc, sel_ns;
    wire [WR_IDX_W-1:0]  num_ru_processed;
    wire [RU_IDX_W-1:0]  ru_idx_dispatched;

    rdo_top #(
        .RU_SIZE_LOG2(RU_SIZE_LOG2),
        .RU_IDX_W    (RU_IDX_W),
        .NUM_RU      (NUM_RU),
        .WR_IDX_W    (WR_IDX_W),
        .HR_DELAY    (HR_DELAY)
    ) u_rdo_top (
        .clk               (clk),
        .rst               (rst),
        .clear             (clear),
        .valid_in          (valid_in),
        .sof               (sof),
        .hr_px             (hr_px),
        .none_px           (none_px),
        .pc_px             (pc_px),
        .ns_px             (ns_px),
        .lambda            (lambda),
        .r_none            (r_none),
        .r_pc              (r_pc),
        .r_ns              (r_ns),
        .sel_none          (sel_none),
        .sel_pc            (sel_pc),
        .sel_ns            (sel_ns),
        .num_ru_processed  (num_ru_processed),
        .ru_idx_dispatched (ru_idx_dispatched)
    );

    // =========================================================================
    // Status readback wiring
    // NUM_RU=64 -> two 32-bit halves per candidate.
    // Zero-extend the narrow counters into the 32-bit STATUS word.
    // =========================================================================
    assign sel_none_lo = sel_none[31:0];
    assign sel_none_hi = sel_none[63:32];
    assign sel_pc_lo   = sel_pc  [31:0];
    assign sel_pc_hi   = sel_pc  [63:32];
    assign sel_ns_lo   = sel_ns  [31:0];
    assign sel_ns_hi   = sel_ns  [63:32];

    // STATUS layout (readable at offset 0x14):
    //   [7:0]   = num_ru_processed
    //   [15:8]  = ru_idx_dispatched
    //   [31:16] = starvation_ctr
    assign status_word = {starvation_ctr,
                          {(8 - RU_IDX_W){1'b0}}, ru_idx_dispatched,
                          {(8 - WR_IDX_W){1'b0}}, num_ru_processed};

    endmodule
