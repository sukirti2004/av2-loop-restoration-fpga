`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: feature_compute  (4-stage pipelined)
//
// Original single-cycle path:
//   pixels_flat FF → lap (LUT) → |abs| (LUT) → 25-input sum (CARRY4 chain)
//                 → ×21049 (DSP) → feat FF
//   Total: ~17.9 ns → fails 65 MHz by 3.4 ns
//
// Fix: 4-stage pipeline breaking after |abs|, after partial sums, after
//      full sum, and at DSP output.
//
//   Stage 1 : pixels → laplacian → |abs| → abs_r FF          (~4 ns)
//   Stage 2a: abs_r  → 5 groups of 5 → ph/pv/pd/pa regs     (~5 ns)
//   Stage 2b: partials → sum_r FF                            (~4 ns)
//   Stage 3 : sum_r → ×21049 (DSP) → feat FF                (~6 ns)
//
// All stages < 10 ns → supports 100 MHz.
// Latency: 4 cycles. Valid propagates accordingly.
//////////////////////////////////////////////////////////////////////////////////
module feature_compute (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,
    // 49 pixels from 7×7 patch, row-major: pixel(r,c) = pixels_flat[(r*7+c)*8 +: 8]
    input  wire [49*8-1:0] pixels_flat,
    // 4 directional texture features, Q2.14 signed
    output reg signed [15:0] feat0,   // horizontal
    output reg signed [15:0] feat1,   // vertical
    output reg signed [15:0] feat2,   // diagonal
    output reg signed [15:0] feat3,   // anti-diagonal
    output reg               valid_out
);

// ─────────────────────────────────────────────────────────────────────────────
// Unpack pixels
// ─────────────────────────────────────────────────────────────────────────────
wire [7:0] px [0:48];
genvar k;
generate
    for (k = 0; k < 49; k = k + 1) begin : unpack
        assign px[k] = pixels_flat[k*8 +: 8];
    end
endgenerate

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1 - Laplacian + |abs| → register
//
// At 25 interior positions (r=1..5, c=1..5):
//   lap_h[i] = -px[left] + 2×px[ctr] - px[right]   range: [-510, +510]
//   lap_v[i] = -px[up]   + 2×px[ctr] - px[down]
//   lap_d[i] = -px[ul]   + 2×px[ctr] - px[dr]
//   lap_a[i] = -px[ur]   + 2×px[ctr] - px[dl]
//
// Absolute values registered immediately - breaks the adder chain from
// the lap LUTs into a separate pipeline stage.
//
// Path: pixels_flat FF → 2-3 LUTs (lap) → 1 LUT (|abs|) → abs_r FF  (~4 ns)
// ─────────────────────────────────────────────────────────────────────────────

// Combinational laplacians
wire signed [10:0] lap_h [0:24];
wire signed [10:0] lap_v [0:24];
wire signed [10:0] lap_d [0:24];
wire signed [10:0] lap_a [0:24];

genvar gr, gc;
generate
    for (gr = 1; gr <= 5; gr = gr + 1) begin : row_loop
        for (gc = 1; gc <= 5; gc = gc + 1) begin : col_loop
            assign lap_h[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[gr*7+gc-1]}) +
                ($signed({1'b0, px[gr*7+gc]}) <<< 1) -
                $signed({1'b0, px[gr*7+gc+1]});
            assign lap_v[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+gc]}) +
                ($signed({1'b0, px[gr*7+gc]}) <<< 1) -
                $signed({1'b0, px[(gr+1)*7+gc]});
            assign lap_d[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+(gc-1)]}) +
                ($signed({1'b0, px[gr*7+gc]}) <<< 1) -
                $signed({1'b0, px[(gr+1)*7+(gc+1)]});
            assign lap_a[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+(gc+1)]}) +
                ($signed({1'b0, px[gr*7+gc]}) <<< 1) -
                $signed({1'b0, px[(gr+1)*7+(gc-1)]});
        end
    end
endgenerate

// Combinational absolute value
wire [10:0] abs_h_c [0:24];
wire [10:0] abs_v_c [0:24];
wire [10:0] abs_d_c [0:24];
wire [10:0] abs_a_c [0:24];

genvar j;
generate
    for (j = 0; j < 25; j = j + 1) begin : abs_comb
        assign abs_h_c[j] = lap_h[j][10] ? -lap_h[j] : lap_h[j];
        assign abs_v_c[j] = lap_v[j][10] ? -lap_v[j] : lap_v[j];
        assign abs_d_c[j] = lap_d[j][10] ? -lap_d[j] : lap_d[j];
        assign abs_a_c[j] = lap_a[j][10] ? -lap_a[j] : lap_a[j];
    end
endgenerate

// Stage 1 output registers (100 × 11-bit = 1100 FFs)
reg [10:0] abs_h_r [0:24];
reg [10:0] abs_v_r [0:24];
reg [10:0] abs_d_r [0:24];
reg [10:0] abs_a_r [0:24];
reg valid_s1;

genvar m;
generate
    for (m = 0; m < 25; m = m + 1) begin : abs_reg
        always @(posedge clk) begin
            if (valid_in) begin
                abs_h_r[m] <= abs_h_c[m];
                abs_v_r[m] <= abs_v_c[m];
                abs_d_r[m] <= abs_d_c[m];
                abs_a_r[m] <= abs_a_c[m];
            end
        end
    end
endgenerate

always @(posedge clk) begin
    if (!resetn) valid_s1 <= 1'b0;
    else         valid_s1 <= valid_in;
end

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 2a - 5 partial sums of 5 values each, for all 4 directions
//
// Breaking the 25-input sum into two stages eliminates the critical
// CARRY4×5 chain that was 11 ns.  Each 5-input sum is ~2 CARRY4 (~5 ns).
// Max partial: 5 × 510 = 2550 < 2^12 → 13 bits sufficient.
// ─────────────────────────────────────────────────────────────────────────────
reg [12:0] ph0, ph1, ph2, ph3, ph4;   // horizontal partials
reg [12:0] pv0, pv1, pv2, pv3, pv4;   // vertical
reg [12:0] pd0, pd1, pd2, pd3, pd4;   // diagonal
reg [12:0] pa0, pa1, pa2, pa3, pa4;   // anti-diagonal
reg valid_s2a;

always @(posedge clk) begin
    if (!resetn) valid_s2a <= 1'b0;
    else begin
        valid_s2a <= valid_s1;
        if (valid_s1) begin
            // horizontal
            ph0 <= abs_h_r[0]  + abs_h_r[1]  + abs_h_r[2]  + abs_h_r[3]  + abs_h_r[4];
            ph1 <= abs_h_r[5]  + abs_h_r[6]  + abs_h_r[7]  + abs_h_r[8]  + abs_h_r[9];
            ph2 <= abs_h_r[10] + abs_h_r[11] + abs_h_r[12] + abs_h_r[13] + abs_h_r[14];
            ph3 <= abs_h_r[15] + abs_h_r[16] + abs_h_r[17] + abs_h_r[18] + abs_h_r[19];
            ph4 <= abs_h_r[20] + abs_h_r[21] + abs_h_r[22] + abs_h_r[23] + abs_h_r[24];
            // vertical
            pv0 <= abs_v_r[0]  + abs_v_r[1]  + abs_v_r[2]  + abs_v_r[3]  + abs_v_r[4];
            pv1 <= abs_v_r[5]  + abs_v_r[6]  + abs_v_r[7]  + abs_v_r[8]  + abs_v_r[9];
            pv2 <= abs_v_r[10] + abs_v_r[11] + abs_v_r[12] + abs_v_r[13] + abs_v_r[14];
            pv3 <= abs_v_r[15] + abs_v_r[16] + abs_v_r[17] + abs_v_r[18] + abs_v_r[19];
            pv4 <= abs_v_r[20] + abs_v_r[21] + abs_v_r[22] + abs_v_r[23] + abs_v_r[24];
            // diagonal
            pd0 <= abs_d_r[0]  + abs_d_r[1]  + abs_d_r[2]  + abs_d_r[3]  + abs_d_r[4];
            pd1 <= abs_d_r[5]  + abs_d_r[6]  + abs_d_r[7]  + abs_d_r[8]  + abs_d_r[9];
            pd2 <= abs_d_r[10] + abs_d_r[11] + abs_d_r[12] + abs_d_r[13] + abs_d_r[14];
            pd3 <= abs_d_r[15] + abs_d_r[16] + abs_d_r[17] + abs_d_r[18] + abs_d_r[19];
            pd4 <= abs_d_r[20] + abs_d_r[21] + abs_d_r[22] + abs_d_r[23] + abs_d_r[24];
            // anti-diagonal
            pa0 <= abs_a_r[0]  + abs_a_r[1]  + abs_a_r[2]  + abs_a_r[3]  + abs_a_r[4];
            pa1 <= abs_a_r[5]  + abs_a_r[6]  + abs_a_r[7]  + abs_a_r[8]  + abs_a_r[9];
            pa2 <= abs_a_r[10] + abs_a_r[11] + abs_a_r[12] + abs_a_r[13] + abs_a_r[14];
            pa3 <= abs_a_r[15] + abs_a_r[16] + abs_a_r[17] + abs_a_r[18] + abs_a_r[19];
            pa4 <= abs_a_r[20] + abs_a_r[21] + abs_a_r[22] + abs_a_r[23] + abs_a_r[24];
        end
    end
end

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 2b - sum 5 partials → final directional sums
//
// 5-input sum of 13-bit values: max = 5 × 2550 = 12750 < 2^14.  ✓
// Path: partial regs → 5-input adder (~3 CARRY4) → sum_r FF  (~4 ns)
// ─────────────────────────────────────────────────────────────────────────────
reg [13:0] sum_h_r, sum_v_r, sum_d_r, sum_a_r;
reg valid_s2;

always @(posedge clk) begin
    if (!resetn) valid_s2 <= 1'b0;
    else begin
        valid_s2 <= valid_s2a;
        if (valid_s2a) begin
            sum_h_r <= ph0 + ph1 + ph2 + ph3 + ph4;
            sum_v_r <= pv0 + pv1 + pv2 + pv3 + pv4;
            sum_d_r <= pd0 + pd1 + pd2 + pd3 + pd4;
            sum_a_r <= pa0 + pa1 + pa2 + pa3 + pa4;
        end
    end
end

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 3 - Scale × 21049, output Q2.14
//
// feat = (sum × 21049)[28:13]
//   21049 / 8192 = 2.5694 ≈ 1/(25×255) × 2^14  (normalise to [0,1] × 2^14)
//   Product is 30-bit; bits [28:13] give the 16-bit Q2.14 result.
//
// Path: sum_r FF → route → DSP48 multiply → feat FF  (~6 ns)
// ─────────────────────────────────────────────────────────────────────────────
wire [29:0] scale_h, scale_v, scale_d, scale_a;
assign scale_h = sum_h_r * 16'd21049;
assign scale_v = sum_v_r * 16'd21049;
assign scale_d = sum_d_r * 16'd21049;
assign scale_a = sum_a_r * 16'd21049;

// ADD THESE 4 LINES:
wire [29:0] scale_h_r = scale_h + 30'd4096;
wire [29:0] scale_v_r = scale_v + 30'd4096;
wire [29:0] scale_d_r = scale_d + 30'd4096;
wire [29:0] scale_a_r = scale_a + 30'd4096;

always @(posedge clk) begin
    if (!resetn) begin
        feat0     <= 16'd0;
        feat1     <= 16'd0;
        feat2     <= 16'd0;
        feat3     <= 16'd0;
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_s2;
        if (valid_s2) begin
            feat0 <= scale_h_r[28:13];
            feat1 <= scale_v_r[28:13];
            feat2 <= scale_d_r[28:13];
            feat3 <= scale_a_r[28:13];
        end
    end
end

endmodule