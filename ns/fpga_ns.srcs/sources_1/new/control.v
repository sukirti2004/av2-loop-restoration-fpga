`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 16.07.2026 22:22:29
// Design Name:
// Module Name: control
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

// -----------------------------------------------------------------------------
// control.v — runtime-width variant
//
// Tracks the pixel raster position and pulses `swap` on RU boundaries
// (i.e., whenever the pixel crosses into a new RU_SIZE × RU_SIZE RU tile).
//
//   RU (r, c) covers pixels rows r*RU_SIZE .. r*RU_SIZE+RU_SIZE-1
//                          cols c*RU_SIZE .. c*RU_SIZE+RU_SIZE-1
//   RU_SHIFT = log2(RU_SIZE).  Default RU_SHIFT=8 -> RU_SIZE=256.
//
// SOF is expected to be high on the first pixel of each frame; it forces
// the effective position back to (0,0) and (combined with valid_in) causes
// a swap pulse on that first pixel.
//
// Runtime-width change vs. the fixed-parameter predecessor:
//   The old design used two fixed-depth shift registers (row_pipe/col_pipe)
//   sized as 3*LINE_W+6 / 3, tapped at their far ends. That baked the frame
//   width into the module at synthesis.
//
//   This version uses a counter+pending one-shot per event kind, driven by a
//   runtime img_width port. Safe because the "at most one event of each kind
//   in flight" invariant holds by a large margin:
//     - Time between row_events  = RU_SIZE * img_width cycles
//     - Delay budget             = 3*img_width + 6 cycles
//     - Ratio (worst case W=1080) = ~48× — no overlap.
//   Same argument for col_events (256-cycle spacing vs 3-cycle delay).
//
//   Timing preserved exactly: event-to-swap latency remains ROW_DELAY+1 =
//   3*img_width + 7 for row events; COL_DELAY+1 = 4 for col events.
//
// See project_ns_ru_swap_bug for the empirical derivation of the +6 / +3
// constants; those are unchanged (they come from datapath register hops, not
// from frame geometry).
// -----------------------------------------------------------------------------

module control #(
    parameter integer MAX_W    = 1920,   // widest frame this instance will ever process
    parameter integer RU_SHIFT = 8       // log2(RU_SIZE); RU_SIZE=256 fixed per paper
)(
    input  wire        clk,
    input  wire        rst,
    // start_pulse: 1-cycle pulse from wrapper on each new frame. Clears the
    // pending flags and counters so Run N doesn't inherit Run N-1's in-flight
    // events. See project_ns_multi_frame_state_carryover.
    input  wire        start_pulse,
    input  wire [10:0] img_width,        // runtime frame width; must be <= MAX_W
    input  wire        valid_in,
    input  wire        sof,
    output reg         swap,
    // Latched RU coords driving tap_reg_file's rd_ru_idx. Held stable during
    // the row_target/col_target delay windows and only updated ON the fire
    // event that actually swaps live taps — never on the raw input crossing.
    //
    // Why latched (bug fix for 2x2+ RU frames): the combinational version
    // updated the instant input crossed a boundary. In multi-RU-col frames a
    // col_fire from an intervening col-crossing then landed while the row
    // crossing was still in flight (row_target counter counting down), so
    // rd_ru_idx = {new_ru_row, new_ru_col} pointed at the WRONG bank slot for
    // the output pixels being emitted (which were still in the previous
    // RU-row). Manifested as ~99% mismatches on row 253, ~60% on 254/255,
    // reproduced in tb_multi_ru_2x2_verify and observed in HW as clustering
    // at rows 253-255, 509-511, 765-767, 1021-1023.
    output wire [2:0]  ru_row_out,
    output wire [2:0]  ru_col_out
);

    // ---------------------------------------------------------------------
    // Compile-time bounds (sized for worst case, i.e., MAX_W).
    // ---------------------------------------------------------------------
    localparam integer MAX_ROW_DELAY = 3 * MAX_W + 6;
    localparam integer ROW_CTR_W     = $clog2(MAX_ROW_DELAY + 1);
    localparam integer COL_DELAY     = 3;
    localparam integer COL_CTR_W     = $clog2(COL_DELAY + 1);

    // ---------------------------------------------------------------------
    // Raster tracking (unchanged from the fixed-width version, except the
    // wrap condition now uses img_width instead of FRAME_W).
    // ---------------------------------------------------------------------
    reg [15:0] pixel_col;
    reg [15:0] pixel_row;
    reg [15:0] prev_ru_col;
    reg [15:0] prev_ru_row;

    wire [15:0] col_now = sof ? 16'd0 : pixel_col;
    wire [15:0] row_now = sof ? 16'd0 : pixel_row;

    wire [15:0] ru_col_now = col_now >> RU_SHIFT;
    wire [15:0] ru_row_now = row_now >> RU_SHIFT;

    wire ru_col_changed = (ru_col_now != prev_ru_col);
    wire ru_row_changed = (ru_row_now != prev_ru_row);

    // Latched RU indices — see port declaration for the bug this fixes.
    reg [2:0] ru_row_r;
    reg [2:0] ru_col_r;
    assign ru_row_out = ru_row_r;
    assign ru_col_out = ru_col_r;

    // Both events can fire on the same cycle (the (r,W-1)->(r+1,0) raster
    // wrap that ALSO crosses an RU-row boundary toggles both ru_col back to 0
    // AND ru_row forward). We WANT both to fire and both to propagate to
    // their own delayed swap:
    //   - col_fire (short delay, 3 cycles) resets ru_col_r=0 so output rows
    //     253/254/255 (still in the previous RU-row) get RU(*,0)'s taps for
    //     their left halves — without this a stale ru_col_r=1 from the last
    //     col-256 crossing pins taps to RU(*,1) for the last row before the
    //     RU-row transition. This was the "row 253 cols 3..255 all wrong"
    //     defect that survived the initial latch fix.
    //   - row_fire (long delay, 3*W+5 cycles) latches ru_row_r forward when
    //     output finally reaches the new RU-row.
    // Safe: their pending counters are independent, and col fires at cycle 3
    // while row fires at cycle 3*W+5 — no overlap on the "at most one in
    // flight per kind" invariant.
    wire row_event = ru_row_changed;
    wire col_event = ru_col_changed;

    // ---------------------------------------------------------------------
    // Counter-based one-shot delays. Replaces the shift-register row_pipe /
    // col_pipe from the previous design.
    // ---------------------------------------------------------------------
    reg                  row_pending;
    reg [ROW_CTR_W-1:0]  row_ctr;
    // row_target = 3*img_width + 6 - 1  (0-indexed final count).
    // Sized to fit in ROW_CTR_W bits (worst case 3*MAX_W+5).
    // REGISTERED to break the combinational multiply out of the row_fire /
    // row_ctr reset path (100 MHz WNS timing fix 2026-08-14). img_width is
    // quasi-static (only changes on start_pulse in ns_filter_top), so a
    // 1-cycle latency here is invisible before the first row event.
    reg [ROW_CTR_W-1:0] row_target;
    always @(posedge clk) begin
        if (rst) row_target <= {ROW_CTR_W{1'b0}};
        else     row_target <= 3 * img_width + 5;
    end

    reg                  col_pending;
    reg [COL_CTR_W-1:0]  col_ctr;

    wire row_fire = row_pending && (row_ctr == row_target);
    wire col_fire = col_pending && (col_ctr == (COL_DELAY - 1));

    always @(posedge clk) begin
        if (rst || start_pulse) begin
            pixel_col   <= 16'd0;
            pixel_row   <= 16'd0;
            prev_ru_col <= 16'hFFFF;
            prev_ru_row <= 16'hFFFF;
            swap        <= 1'b0;
            row_pending <= 1'b0;
            row_ctr     <= {ROW_CTR_W{1'b0}};
            col_pending <= 1'b0;
            col_ctr     <= {COL_CTR_W{1'b0}};
            ru_row_r    <= 3'd0;
            ru_col_r    <= 3'd0;
        end else if (valid_in) begin
            // -------- row one-shot --------
            if (row_fire) begin
                // Rare-but-valid: a new event fires on the exact cycle the
                // previous one exits (invariant margin makes this ~48× safe).
                row_pending <= row_event;
                row_ctr     <= {ROW_CTR_W{1'b0}};
            end else if (row_event) begin
                // synthesis translate_off
                if (row_pending)
                    $error("control.v: row_event while row_pending at t=%0t (invariant violated)", $time);
                // synthesis translate_on
                row_pending <= 1'b1;
                row_ctr     <= {ROW_CTR_W{1'b0}};
            end else if (row_pending) begin
                row_ctr <= row_ctr + 1'b1;
            end

            // -------- col one-shot --------
            if (col_fire) begin
                col_pending <= col_event;
                col_ctr     <= {COL_CTR_W{1'b0}};
            end else if (col_event) begin
                // synthesis translate_off
                if (col_pending)
                    $error("control.v: col_event while col_pending at t=%0t (invariant violated)", $time);
                // synthesis translate_on
                col_pending <= 1'b1;
                col_ctr     <= {COL_CTR_W{1'b0}};
            end else if (col_pending) begin
                col_ctr <= col_ctr + 1'b1;
            end

            swap        <= row_fire | col_fire;
            prev_ru_col <= ru_col_now;
            prev_ru_row <= ru_row_now;

            // Latch RU indices on the fire event that actually swaps taps.
            // On row_fire, ru_col also latches (raster wrap already reset it).
            // On col_fire, only ru_col updates; ru_row stays.
            if (row_fire) begin
                ru_row_r <= ru_row_now[2:0];
                ru_col_r <= ru_col_now[2:0];
            end else if (col_fire) begin
                ru_col_r <= ru_col_now[2:0];
            end

            if (col_now == img_width - 1'b1) begin
                pixel_col <= 16'd0;
                pixel_row <= row_now + 16'd1;
            end else begin
                pixel_col <= col_now + 16'd1;
                pixel_row <= row_now;
            end
        end else begin
            swap <= 1'b0;
        end
    end

endmodule
