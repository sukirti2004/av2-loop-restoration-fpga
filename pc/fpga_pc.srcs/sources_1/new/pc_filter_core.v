`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.06.2026 09:48:32
// Design Name: 
// Module Name: pc_filter_core
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module pc_filter_core (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,

    input  wire [49*8-1:0] pixels_flat,

    // replace the 28 threshold ports with:
    input wire [15:0] t0,t1,t2,t3,t4,t5,t6,

    output wire [7:0]  pixel_out,
    output wire        valid_out
);

// ── Stage 1: Feature Computation ─────────────────────────────────
wire signed [15:0] feat0, feat1, feat2, feat3;
wire feat_valid;

feature_compute u_feat (
    .clk(clk), .resetn(resetn), .valid_in(valid_in),
    .pixels_flat(pixels_flat),
    .feat0(feat0), .feat1(feat1), .feat2(feat2), .feat3(feat3),
    .valid_out(feat_valid)
);

// ── Stage 2: Quantizer → Context Index ───────────────────────────
wire [11:0] ctx;
wire ctx_valid;

// and the instantiation:
quantizer_ctx u_quant (
    .clk(clk), .resetn(resetn), .valid_in(feat_valid),
    .feat0(feat0),.feat1(feat1),.feat2(feat2),.feat3(feat3),
    .t0(t0),.t1(t1),.t2(t2),.t3(t3),.t4(t4),.t5(t5),.t6(t6),
    .ctx_out(ctx), .valid_out(ctx_valid)
);

// ── Stage 3: Cluster LUT ─────────────────────────────────────────
wire [7:0] filter_id;
wire fid_valid;

cluster_lut u_clut (
    .clk(clk), .valid_in(ctx_valid),
    .ctx_in(ctx),
    .filter_id(filter_id), .valid_out(fid_valid)
);

// ── Stage 4: Filter LUT ──────────────────────────────────────────
wire [49*16-1:0] taps_flat;
wire taps_valid;

filter_lut u_flut (
    .clk(clk), .valid_in(fid_valid),
    .filter_id(filter_id),
    .taps_flat(taps_flat), .valid_out(taps_valid)
);

// ── Pixel delay: 7 stages to align with taps at MAC input ────────
//
// Depth = feature_compute(4) + quantizer_ctx(1) + cluster_lut(1)
//       + filter_lut(1) = 7 stages.
//
// IMPORTANT: this chain MUST be gated by valid_in.
//
// Every stage in the taps path advances only when its valid is high
// (feature_compute uses `if (valid_s1)`, filter_lut uses `if (valid_in)`,
// etc.).  line_buffer's valid_out is NOT continuous — it is low for the
// first 6 columns of every row and for the first 6 rows, because a full
// 7x7 window does not exist there.
//
// If this chain shifted on every clock while the taps path stalled during
// those gaps, the two would desynchronise and the MAC would combine a
// patch with taps computed for a different patch.  Gating on valid_in
// keeps both paths advancing in lockstep regardless of gaps.
//
// Note this is invisible in a single-patch testbench (pixels_flat is held
// static) and nearly invisible on flat or linear-gradient images (local
// context barely changes, so wrong taps ≈ right taps).  It only shows up
// on real textured content.

reg [49*8-1:0] px_d [0:6];
always @(posedge clk) begin
    if (valid_in) begin
        px_d[0] <= pixels_flat;
        px_d[1] <= px_d[0];
        px_d[2] <= px_d[1];
        px_d[3] <= px_d[2];
        px_d[4] <= px_d[3];
        px_d[5] <= px_d[4];
        px_d[6] <= px_d[5];
    end
end

// ── Stage 5: MAC Engine ──────────────────────────────────────────
mac_engine u_mac (
    .clk(clk), .resetn(resetn), .valid_in(taps_valid),
    .pixels_flat(px_d[6]),
    .taps_flat(taps_flat),
    .pixel_out(pixel_out), .valid_out(valid_out)
);

endmodule