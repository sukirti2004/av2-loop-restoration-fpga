`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// stream_sync.v
//
// 4-way AXI-Stream handshake combiner. Reads 4 independent AXI-Stream slave
// ports (each expected to be fed from its own axis_data_fifo instance in the
// block diagram) and emits a single synchronized (valid, hr, none, pc, ns)
// tuple to rdo_top.
//
// Handshake rule:
//   all_valid = tvalid_hr & tvalid_none & tvalid_pc & tvalid_ns
//   valid_in (to rdo_top) = all_valid
//   tready_x (to each upstream FIFO) = all_valid  (pop all 4 together)
//
// So a beat is consumed only when EVERY upstream stream has data. If one
// FIFO runs empty the whole set stalls; if one runs ahead its FIFO fills
// and back-pressures its DMA. Self-balancing.
//
// TDATA is 32-bit per stream (wizard-forced minimum) but only bits[7:0]
// carry the actual pixel; upper 24 bits are zero-padded by the PS driver.
//
// STARVATION COUNTER: increments every clock where at least one tvalid is 1
// but not all 4 are 1 (i.e., some stream has data but the others don't yet).
// Non-zero readback after a frame => the FIFOs in the BD are too shallow for
// the observed skew. Wraps at 16 bits.
// -----------------------------------------------------------------------------

module stream_sync (
    input  wire        clk,
    input  wire        rst,           // active-high

    // 4 upstream AXI-Stream slaves (from BD's axis_data_fifo blocks)
    input  wire        s_hr_tvalid,
    output wire        s_hr_tready,
    input  wire [31:0] s_hr_tdata,

    input  wire        s_none_tvalid,
    output wire        s_none_tready,
    input  wire [31:0] s_none_tdata,

    input  wire        s_pc_tvalid,
    output wire        s_pc_tready,
    input  wire [31:0] s_pc_tdata,

    input  wire        s_ns_tvalid,
    output wire        s_ns_tready,
    input  wire [31:0] s_ns_tdata,

    // Synchronized outputs to rdo_top
    output wire        valid_in,
    output wire [7:0]  hr_px,
    output wire [7:0]  none_px,
    output wire [7:0]  pc_px,
    output wire [7:0]  ns_px,

    // Telemetry (readable via AXI-Lite STATUS reg)
    output reg  [15:0] starvation_ctr
);

    wire all_valid = s_hr_tvalid & s_none_tvalid & s_pc_tvalid & s_ns_tvalid;
    wire any_valid = s_hr_tvalid | s_none_tvalid | s_pc_tvalid | s_ns_tvalid;

    // Shared TREADY: pop from all 4 FIFOs on the same cycle, only when all
    // 4 have valid data. This is the AXI-Stream way to co-fire multiple
    // slaves in lockstep.
    assign s_hr_tready   = all_valid;
    assign s_none_tready = all_valid;
    assign s_pc_tready   = all_valid;
    assign s_ns_tready   = all_valid;

    assign valid_in = all_valid;
    assign hr_px    = s_hr_tdata  [7:0];
    assign none_px  = s_none_tdata[7:0];
    assign pc_px    = s_pc_tdata  [7:0];
    assign ns_px    = s_ns_tdata  [7:0];

    // Starvation: some streams have data but not all. Saturating 16-bit.
    always @(posedge clk) begin
        if (rst) begin
            starvation_ctr <= 16'd0;
        end else if (any_valid && !all_valid) begin
            if (starvation_ctr != 16'hFFFF)
                starvation_ctr <= starvation_ctr + 16'd1;
        end
    end

endmodule
