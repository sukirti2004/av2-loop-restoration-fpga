`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: mac_engine  (3-stage pipelined)
//
// Original problem: all 49 products and the full 49-input sum were computed
// COMBINATIONALLY in one clock cycle.  Vivado synthesised that sum as a
// 12-level CARRY4 ripple-carry chain (~15.5 ns), making the total critical
// path 24 ns - barely meeting 40 MHz, and nowhere near the 63 MHz needed
// for 30 fps @ 1080p.
//
// Fix: break the computation into 3 registered pipeline stages.
//
//   Stage 1 - Multiply
//     49 DSP48E1 multiplies: px[k] × tap[k] → prod_r[k]
//     Path: taps_flat BRAM reg → routing → DSP48 → prod_r FF  (~9.5 ns)
//
//   Stage 2 - Partial sums
//     7 groups of 7 products, each summed to a 30-bit partial result → psum_r[g]
//     Path: prod_r FF → 7-input 30-bit adder tree → psum_r FF  (~7 ns)
//
//   Stage 3 - Final accumulate + output
//     7 partial sums summed, right-shifted by 13 (remove Q3.13 scale),
//     clipped to [0,255] → pixel_out FF
//     Path: psum_r FF → 7-input 30-bit adder tree → shift/clip → pixel_out FF (~8 ns)
//
// All three stages target < 12 ns → supports 80-100 MHz.
//
// Latency vs original: +2 clock cycles (3 total instead of 1).
//   valid_out is therefore 2 cycles later relative to valid_in.
//   This is transparent to the streaming pipeline - valid simply propagates.
//
// Bit-width analysis (all using actual pixel/tap value ranges):
//   product:    px ∈ [0,255], tap ∈ [-32768,32767]  →  max|product| = 8,355,585  < 2^23
//               stored as signed [29:0] (30-bit, zero waste, avoids truncation warnings)
//   partial sum: 7 × 8,355,585 = 58,489,095  < 2^26  →  fits in 30-bit signed  ✓
//   final sum:   7 × 58,489,095 = 409,423,665 < 2^29  →  fits in 30-bit signed  ✓
//   shifted:     final_sum >>> 13 → max ≈ 50,000  →  clip to [0,255]  ✓
//////////////////////////////////////////////////////////////////////////////////
module mac_engine (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,
    // 49 pixels from 7×7 patch, each 8-bit unsigned
    input  wire [49*8-1:0]  pixels_flat,
    // 49 filter taps from LUT, each 16-bit Q3.13 signed
    input  wire [49*16-1:0] taps_flat,
    // filtered output pixel (Q0 unsigned, clipped to [0,255])
    output reg  [7:0]  pixel_out,
    output reg         valid_out
);

// ─────────────────────────────────────────────────────────────────────────────
// Unpack flat buses into arrays
// ─────────────────────────────────────────────────────────────────────────────
wire        [7:0]  px  [0:48];
wire signed [15:0] tap [0:48];

genvar k;
generate
    for (k = 0; k < 49; k = k + 1) begin : unpack
        assign px[k]  = pixels_flat[k*8  +: 8];
        assign tap[k] = $signed(taps_flat[k*16 +: 16]);
    end
endgenerate

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1 - Multiply: 49 × DSP48 → registered products
//
// Each `always` block infers one DSP48E1 (Vivado sees a single multiply per
// always block with a direct FF on the output).
//
// px[k] is 8-bit unsigned.  Prepending 1'b0 makes it a 9-bit signed non-
// negative value, which is the correct input format for a signed DSP multiply.
// The 25-bit product is sign-extended on assignment to the 30-bit register.
//
// Critical path this stage:
//   taps_flat BRAM output (2.5 ns) → net (2.2 ns) → DSP48 multiply (3.8 ns)
//   → net to FF (1 ns) ≈ 9.5 ns  →  supports 100+ MHz
// ─────────────────────────────────────────────────────────────────────────────
reg signed [29:0] prod_r [0:48];
reg               valid_s1;

generate
    for (k = 0; k < 49; k = k + 1) begin : mult_stage
        always @(posedge clk) begin
            if (valid_in)
                prod_r[k] <= $signed({1'b0, px[k]}) * tap[k];
        end
    end
endgenerate

always @(posedge clk) begin
    if (!resetn) valid_s1 <= 1'b0;
    else         valid_s1 <= valid_in;
end

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 2 - Partial sums: 7 groups of 7 products → 7 registered partial sums
//
// prod_r[k] are all 30-bit signed, so the additions are performed in 30-bit
// signed arithmetic - no silent overflow possible (max sum = 58.5M < 2^26). ✓
//
// Vivado synthesises each 7-input addition as a balanced tree (~3 adder levels,
// each ~30 bits wide).  Estimated path: FF → tree → FF ≈ 6-7 ns → 140+ MHz.
// ─────────────────────────────────────────────────────────────────────────────
reg signed [29:0] psum_r [0:6];
reg               valid_s2;

reg signed [29:0] pa_r [0:6];  // first 4 products of each group
reg signed [29:0] pb_r [0:6];  // last  3 products of each group
reg valid_s2a;

always @(posedge clk) begin
    if (!resetn) valid_s2a <= 0;
    else begin
        valid_s2a <= valid_s1;
        if (valid_s1) begin
            pa_r[0] <= prod_r[0]  + prod_r[1]  + prod_r[2]  + prod_r[3];
            pb_r[0] <= prod_r[4]  + prod_r[5]  + prod_r[6];
            pa_r[1] <= prod_r[7]  + prod_r[8]  + prod_r[9]  + prod_r[10];
            pb_r[1] <= prod_r[11] + prod_r[12] + prod_r[13];
            pa_r[2] <= prod_r[14] + prod_r[15] + prod_r[16] + prod_r[17];
            pb_r[2] <= prod_r[18] + prod_r[19] + prod_r[20];
            pa_r[3] <= prod_r[21] + prod_r[22] + prod_r[23] + prod_r[24];
            pb_r[3] <= prod_r[25] + prod_r[26] + prod_r[27];
            pa_r[4] <= prod_r[28] + prod_r[29] + prod_r[30] + prod_r[31];
            pb_r[4] <= prod_r[32] + prod_r[33] + prod_r[34];
            pa_r[5] <= prod_r[35] + prod_r[36] + prod_r[37] + prod_r[38];
            pb_r[5] <= prod_r[39] + prod_r[40] + prod_r[41];
            pa_r[6] <= prod_r[42] + prod_r[43] + prod_r[44] + prod_r[45];
            pb_r[6] <= prod_r[46] + prod_r[47] + prod_r[48];
        end
    end
end

always @(posedge clk) begin
    if (!resetn) valid_s2 <= 0;
    else begin
        valid_s2 <= valid_s2a;
        if (valid_s2a) begin
            psum_r[0] <= pa_r[0] + pb_r[0];
            psum_r[1] <= pa_r[1] + pb_r[1];
            psum_r[2] <= pa_r[2] + pb_r[2];
            psum_r[3] <= pa_r[3] + pb_r[3];
            psum_r[4] <= pa_r[4] + pb_r[4];
            psum_r[5] <= pa_r[5] + pb_r[5];
            psum_r[6] <= pa_r[6] + pb_r[6];
        end
    end
end


// ─────────────────────────────────────────────────────────────────────────────
// STAGE 3 - Final accumulate, Q3.13 → Q0 shift, saturating clip
//
// Sum the 7 partial sums.  All operands are 30-bit signed; max sum = 409.5M
// which fits in 30-bit signed (range ±536.9M). ✓
//
// Right-shift by 13 removes the Q3.13 fractional scale.
// Result is clipped to the unsigned 8-bit range [0, 255].
//
// Estimated path: psum_r FF → 7-input adder tree (~3 levels) → shift → clip
//                 → pixel_out FF  ≈ 8-9 ns → supports 110+ MHz
// ─────────────────────────────────────────────────────────────────────────────
// FIX - force LUT/CARRY4 balanced adder tree instead
// Stage 3a: accumulate 7 partial sums → register in a regular FF
(* use_dsp = "no" *) reg signed [29:0] final_sum_r;
reg valid_s3a;

always @(posedge clk) begin
    if (!resetn) valid_s3a <= 0;
    else begin
        valid_s3a <= valid_s2;
        if (valid_s2)
            final_sum_r <= psum_r[0] + psum_r[1] + psum_r[2] + psum_r[3]
                         + psum_r[4] + psum_r[5] + psum_r[6];
    end
end

// Stage 3b: shift, clip → pixel_out  (+ 4096 = round to nearest, not truncate)
wire signed [29:0] shifted;
assign shifted = (final_sum_r + 30'sd4096) >>> 13;

always @(posedge clk) begin
    if (!resetn) begin
        pixel_out <= 8'd0;
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_s3a;
        if (valid_s3a) begin
            if      (shifted > 30'sd255) pixel_out <= 8'd255;
            else if (shifted < 30'sd0)   pixel_out <= 8'd0;
            else                         pixel_out <= shifted[7:0];
        end
    end
end

endmodule