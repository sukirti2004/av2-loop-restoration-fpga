`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// mse_accumulator.v
//
// Streaming Σ(candidate − hr)² accumulator with per-RU latch and reset.
//
// Consumes one (candidate, hr) pixel pair per cycle when `valid_in` is high.
// Computes the squared difference and adds it to a running accumulator that
// spans one restoration unit (RU). When `swap` is asserted on the same cycle
// as the LAST pixel of an RU, the accumulator latches its final total
// (including that pixel's contribution) onto `mse_out` with a single-cycle
// `mse_valid` pulse, then resets to 0 for the next RU.
//
// Instantiated 3× in rdo_top (NONE, PC, NS candidates). Each instance's
// (valid_in, candidate_px, hr_px, swap) must be time-aligned to that
// candidate's own pipeline latency; hr is delayed externally by
// `hr_delay_line` (depth 0 for NONE, ~6 for PC, ~7 for NS — final numbers
// calibrated in Phase 2 against multi-RU golden vectors).
//
// Pipeline: 3 clocks from (valid_in + swap) to (mse_valid + mse_out).
// Stages: diff (int10) → sqdiff (uint17) → accumulate/latch (uint33).
// Downstream cost_compare must wait for `mse_valid` before reading `mse_out`.
//
// Bit-plan:
//   candidate_px, hr_px : uint8   [0, 255]
//   diff_r              : int10   [−255, +255]   (2-bit sign-extended for margin)
//   diff_sq_full        : int20   sign×sign product; value ≤ 65025 so upper bits are 0
//   sqdiff_r            : uint17  [0, 65025]
//   acc_r, mse_out      : uint33  max Σ over one RU = 256·256·65025 = 4.27e9
//                                 < 2^33 = 8.59e9 (2× headroom over uint32)
//
// Pipeline advance is gated on the per-stage valid signal (matches NS
// `control.v` convention). Bubbles (`valid_in = 0`) freeze in-flight data
// in place; they do not corrupt the accumulator because non-valid cycles
// contribute nothing.
// -----------------------------------------------------------------------------

module mse_accumulator (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [7:0]  candidate_px,
    input  wire [7:0]  hr_px,
    input  wire        swap,          // marks last pixel of current RU
    output reg  [32:0] mse_out,       // uint33 total for the RU that just ended
    output reg         mse_valid      // one-cycle pulse when mse_out becomes fresh
);

    // =========================================================================
    // Stage 1: diff (int10)
    // =========================================================================
    reg signed [9:0] diff_r;
    reg              s1_valid;
    reg              s1_swap;

    always @(posedge clk) begin
        if (rst) begin
            diff_r   <= 10'sd0;
            s1_valid <= 1'b0;
            s1_swap  <= 1'b0;
        end else begin
            if (valid_in) begin
                diff_r  <= $signed({2'b00, candidate_px})
                         - $signed({2'b00, hr_px});
                s1_swap <= swap;
            end
            s1_valid <= valid_in;
        end
    end

    // =========================================================================
    // Stage 2: squared diff (uint17)
    // diff * diff is signed×signed → int20, but the result is always
    // non-negative and ≤ 65025, so upper bits [19:17] are guaranteed 0.
    // =========================================================================
    reg [16:0] sqdiff_r;
    reg        s2_valid;
    reg        s2_swap;

    wire signed [19:0] diff_sq_full = diff_r * diff_r;

    always @(posedge clk) begin
        if (rst) begin
            sqdiff_r <= 17'd0;
            s2_valid <= 1'b0;
            s2_swap  <= 1'b0;
        end else begin
            if (s1_valid) begin
                sqdiff_r <= diff_sq_full[16:0];
                s2_swap  <= s1_swap;
            end
            s2_valid <= s1_valid;
        end
    end

    // =========================================================================
    // Stage 3: accumulate + swap-triggered latch
    // On a non-swap valid cycle: acc += sqdiff.
    // On a swap valid cycle: mse_out = acc + this-pixel's sqdiff, then acc = 0.
    // =========================================================================
    reg [32:0] acc_r;

    always @(posedge clk) begin
        if (rst) begin
            acc_r     <= 33'd0;
            mse_out   <= 33'd0;
            mse_valid <= 1'b0;
        end else begin
            mse_valid <= 1'b0;   // default: single-cycle pulse
            if (s2_valid) begin
                if (s2_swap) begin
                    mse_out   <= acc_r + {16'd0, sqdiff_r};
                    mse_valid <= 1'b1;
                    acc_r     <= 33'd0;
                end else begin
                    acc_r <= acc_r + {16'd0, sqdiff_r};
                end
            end
        end
    end

endmodule
