`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// rdo_top.v
//
// Top-level algorithm module for the RDO combiner IP. Wires together:
//   1x rdo_control       -- RU-boundary tracker, generates `swap` pulse
//   3x hr_delay_line     -- HR alignment (DELAY=0 for Option 8 architecture,
//                           kept for future retuning if wrapper DMA sync
//                           reveals per-stream skew)
//   3x mse_accumulator   -- one per candidate (NONE, PC, NS)
//   1x cost_compare      -- computes MSE + lambda*R, argmin over 3 candidates
//   1x selection_regs    -- per-RU bitmap of winners for AXI-Lite readback
//
// INPUT CONTRACT (enforced by wrapper `rdo.v`, NOT by this module):
//   - All 4 pixel streams (hr, none, pc, ns) arrive lock-step
//   - valid_in gates all 4 simultaneously (single shared valid)
//   - Pixels are tile-order per RU: 65536 consecutive valid pixels per RU
//     (for RU_SIZE=256), one RU at a time
//   - hr, none, pc, ns for pixel N of each RU are presented on the same
//     clock cycle -- the wrapper's per-stream FIFOs + combined tready
//     enforce this
//
// FRAME BOUNDARIES:
//   - `sof` pulses on the first valid pixel of each frame (safety re-sync
//     for rdo_control's pixel counter)
//   - `clear` pulses to wipe selection_regs between frames (driven either
//     by sof itself or by an AXI-Lite write in the wrapper)
//
// PARAMETERS (default): 1080p at RU=256 supports up to 60 RUs. NUM_RU=64
// covers 1080p and gives headroom for 4K. HR_DELAY=0 for Option 8 (all
// streams DDR-aligned at wrapper output).
//
// LATENCY: from swap pulse to sel_xxx bit update is
//   3 (mse_accumulator) + 1 (cost_compare) + 1 (selection_regs write) = 5 cycles.
// -----------------------------------------------------------------------------

module rdo_top #(
    parameter integer RU_SIZE_LOG2 = 8,       // RU_SIZE = 256
    parameter integer RU_IDX_W     = 6,
    parameter integer NUM_RU       = 64,
    parameter integer WR_IDX_W     = 6,
    parameter integer HR_DELAY     = 0        // v1: all DDR-aligned
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 clear,         // frame boundary; clears selection_regs

    // Streaming inputs (all 4 lock-step; wrapper responsibility)
    input  wire                 valid_in,
    input  wire                 sof,
    input  wire [7:0]           hr_px,
    input  wire [7:0]           none_px,
    input  wire [7:0]           pc_px,
    input  wire [7:0]           ns_px,

    // AXI-Lite writable parameters (static per frame)
    input  wire [15:0]          lambda,
    input  wire [15:0]          r_none,
    input  wire [15:0]          r_pc,
    input  wire [15:0]          r_ns,

    // AXI-Lite readback outputs
    output wire [NUM_RU-1:0]    sel_none,
    output wire [NUM_RU-1:0]    sel_pc,
    output wire [NUM_RU-1:0]    sel_ns,
    output wire [WR_IDX_W-1:0]  num_ru_processed,
    output wire [RU_IDX_W-1:0]  ru_idx_dispatched   // rdo_control's live counter
);

    // =========================================================================
    // RU-boundary tracker
    // =========================================================================
    wire swap_pulse;

    rdo_control #(
        .RU_SIZE_LOG2(RU_SIZE_LOG2),
        .RU_IDX_W    (RU_IDX_W)
    ) u_rdo_control (
        .clk        (clk),
        .rst        (rst),
        .valid_in   (valid_in),
        .sof        (sof),
        .swap       (swap_pulse),
        .ru_idx_out (ru_idx_dispatched)
    );

    // =========================================================================
    // HR delay lines
    // Three separate instances (one feeding each mse_accumulator) so their
    // DELAY parameters can diverge in the future without touching this file.
    // For v1 all three are DELAY=0 (combinational passthrough via generate).
    // =========================================================================
    wire       hr_valid_none, hr_valid_pc, hr_valid_ns;
    wire [7:0] hr_px_none,    hr_px_pc,    hr_px_ns;

    hr_delay_line #(.DELAY(HR_DELAY)) u_hr_none (
        .clk       (clk),
        .rst       (rst),
        .valid_in  (valid_in),
        .hr_in     (hr_px),
        .valid_out (hr_valid_none),
        .hr_out    (hr_px_none)
    );

    hr_delay_line #(.DELAY(HR_DELAY)) u_hr_pc (
        .clk       (clk),
        .rst       (rst),
        .valid_in  (valid_in),
        .hr_in     (hr_px),
        .valid_out (hr_valid_pc),
        .hr_out    (hr_px_pc)
    );

    hr_delay_line #(.DELAY(HR_DELAY)) u_hr_ns (
        .clk       (clk),
        .rst       (rst),
        .valid_in  (valid_in),
        .hr_in     (hr_px),
        .valid_out (hr_valid_ns),
        .hr_out    (hr_px_ns)
    );

    // =========================================================================
    // Per-candidate MSE accumulators
    // Each takes its candidate pixel + delayed HR + shared swap.
    // =========================================================================
    wire [32:0] mse_none, mse_pc, mse_ns;
    wire        mse_valid_none, mse_valid_pc, mse_valid_ns;

    mse_accumulator u_mse_none (
        .clk          (clk),
        .rst          (rst),
        .valid_in     (hr_valid_none),      // == valid_in when HR_DELAY=0
        .candidate_px (none_px),
        .hr_px        (hr_px_none),
        .swap         (swap_pulse),
        .mse_out      (mse_none),
        .mse_valid    (mse_valid_none)
    );

    mse_accumulator u_mse_pc (
        .clk          (clk),
        .rst          (rst),
        .valid_in     (hr_valid_pc),
        .candidate_px (pc_px),
        .hr_px        (hr_px_pc),
        .swap         (swap_pulse),
        .mse_out      (mse_pc),
        .mse_valid    (mse_valid_pc)
    );

    mse_accumulator u_mse_ns (
        .clk          (clk),
        .rst          (rst),
        .valid_in     (hr_valid_ns),
        .candidate_px (ns_px),
        .hr_px        (hr_px_ns),
        .swap         (swap_pulse),
        .mse_out      (mse_ns),
        .mse_valid    (mse_valid_ns)
    );

    // =========================================================================
    // Cost computation + argmin selection
    // All three mse_valid pulses are coincident (shared swap, identical
    // 3-stage pipelines) so any one suffices as cost_compare's mse_valid.
    // mse_valid_none is chosen arbitrarily.
    // =========================================================================
    wire [1:0] selection;
    wire       selection_valid;

    cost_compare u_cost_compare (
        .clk             (clk),
        .rst             (rst),
        .mse_none        (mse_none),
        .mse_pc          (mse_pc),
        .mse_ns          (mse_ns),
        .mse_valid       (mse_valid_none),
        .lambda          (lambda),
        .r_none          (r_none),
        .r_pc            (r_pc),
        .r_ns            (r_ns),
        .selection       (selection),
        .selection_valid (selection_valid)
    );

    // =========================================================================
    // Selection bitmap storage (readable via AXI-Lite in the wrapper)
    // =========================================================================
    selection_regs #(
        .NUM_RU  (NUM_RU),
        .WR_IDX_W(WR_IDX_W)
    ) u_selection_regs (
        .clk              (clk),
        .rst              (rst),
        .clear            (clear),
        .selection        (selection),
        .selection_valid  (selection_valid),
        .sel_none         (sel_none),
        .sel_pc           (sel_pc),
        .sel_ns           (sel_ns),
        .num_ru_processed (num_ru_processed)
    );

endmodule
