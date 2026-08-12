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
// control.v
//
// Tracks the pixel raster position and pulses `swap` on RU boundaries
// (i.e., whenever the pixel crosses into a new 256x256 RU tile).
//
//   RU (r, c) covers pixels rows r*RU_SIZE .. r*RU_SIZE+RU_SIZE-1
//                          cols c*RU_SIZE .. c*RU_SIZE+RU_SIZE-1
//   RU_SHIFT = log2(RU_SIZE).  Default RU_SHIFT=8 -> RU_SIZE=256.
//
// SOF is expected to be high on the first pixel of each frame; it forces
// the effective position back to (0,0) and (combined with valid_in) causes
// a swap pulse on that first pixel.
// -----------------------------------------------------------------------------

module control #(
    parameter FRAME_W  = 1920,
    parameter LINE_W   = 1920,     // Must match line_buffer W; used for SWAP_DELAY.
    parameter RU_SHIFT = 8
)(
    input  wire clk,
    input  wire rst,
    // start_pulse: 1-cycle pulse from wrapper on each new frame. Resets pipes
    // and prev_ru so Run N doesn't inherit Run N-1's tail state (which would
    // fire spurious swaps early and leave pixel_row/counters mis-phased).
    // See project_ns_multi_frame_state_carryover.
    input  wire start_pulse,
    input  wire valid_in,
    input  wire sof,
    output reg  swap,
    // Combinational RU coords of the current input pixel. At the cycle when
    // `swap` fires (delayed by ROW_DELAY/COL_DELAY), these correctly
    // identify the RU whose taps the output is about to enter (verified
    // via ROW_DELAY = 3*LINE_W + 6 and COL_DELAY = 3 timing calibration).
    // Used by tap_reg_file to index the coefficient bank.
    output wire [2:0] ru_row_out,
    output wire [2:0] ru_col_out
);

    reg [15:0] pixel_col;
    reg [15:0] pixel_row;
    reg [15:0] prev_ru_col;
    reg [15:0] prev_ru_row;

    // Effective position this cycle: sof pulls the counters to (0,0).
    wire [15:0] col_now = sof ? 16'd0 : pixel_col;
    wire [15:0] row_now = sof ? 16'd0 : pixel_row;

    // RU index = position >> RU_SHIFT
    wire [15:0] ru_col_now = col_now >> RU_SHIFT;
    wire [15:0] ru_row_now = row_now >> RU_SHIFT;

    wire ru_col_changed = (ru_col_now != prev_ru_col);
    wire ru_row_changed = (ru_row_now != prev_ru_row);

    // Expose narrow RU coords for tap-bank indexing. 3-bit each = up to 8
    // rows and 8 cols, enough for 1080p at RU=256 (5x8=40 RUs).
    assign ru_row_out = ru_row_now[2:0];
    assign ru_col_out = ru_col_now[2:0];

    // Row-RU and col-RU crossings need DIFFERENT delays because window_former's
    // center trails the newest input by (3 rows, 3 cols). A row-RU crossing must
    // wait 3 full rows of pipeline (3*LINE_W cycles) before its output emerges;
    // a col-RU crossing only needs to wait ~3 cols. Using one shared delay
    // (previous design) worked for the vertical test because that geometry only
    // exercises row crossings, but breaks horizontally: col crossings delayed
    // by 3*LINE_W+6 have phase error = (3*LINE_W+6) mod RU_SIZE, which only
    // shows up as a small 5-column band per row rather than gross corruption.
    //
    // Priority rule: row_event beats col_event on the same cycle. Row-wraps
    // within the same RU-row toggle ru_col back to 0 (a pure col_event —
    // correct, gets the short delay). Row-wraps that DO cross an RU-row
    // boundary also toggle ru_col back to 0 as a side effect (raster order),
    // but the row_event is what actually matters — the col half is incidental
    // geometry and must NOT trigger a separate short-delay swap. Under raster
    // input order, a diagonal jump (both RU-row and RU-col changing to non-
    // zero indices) is unreachable, so this priority rule is sufficient — no
    // need for full per-pixel RU-ID pipelining.
    wire row_event = ru_row_changed;
    wire col_event = ru_col_changed && !ru_row_changed;

    // Delays measured empirically via probe on tap_reg_file.taps_live_r vs.
    // multi-RU golden vectors. Both must be re-derived if pipeline depth in
    // any downstream module (line_buffer / window_former / mult_adder_tree /
    // normalize_saturate) changes.
    //   ROW_DELAY = 3*LINE_W + 6 : 3 rows advance + 3 cols catchup + 3 register
    //                              hops through window_former/mult/normalize.
    //   COL_DELAY = 3            : 3 cols catchup for center to reach col boundary.
    //                              Value being empirically tuned — see [[project_ns_ru_swap_bug]].
    localparam integer ROW_DELAY = 3 * LINE_W + 6;
    localparam integer COL_DELAY = 3;
    reg [ROW_DELAY-1:0] row_pipe;
    reg [COL_DELAY-1:0] col_pipe;

    always @(posedge clk) begin
        if (rst || start_pulse) begin
            pixel_col   <= 16'd0;
            pixel_row   <= 16'd0;
            prev_ru_col <= 16'hFFFF;
            prev_ru_row <= 16'hFFFF;
            swap        <= 1'b0;
            row_pipe    <= {ROW_DELAY{1'b0}};
            col_pipe    <= {COL_DELAY{1'b0}};
        end else if (valid_in) begin
            row_pipe    <= {row_pipe[ROW_DELAY-2:0], row_event};
            col_pipe    <= {col_pipe[COL_DELAY-2:0], col_event};
            swap        <= row_pipe[ROW_DELAY-1] | col_pipe[COL_DELAY-1];
            prev_ru_col <= ru_col_now;
            prev_ru_row <= ru_row_now;

            if (col_now == FRAME_W - 1) begin
                pixel_col <= 16'd0;
                pixel_row <= row_now + 16'd1;
            end else begin
                pixel_col <= col_now + 16'd1;
                // Propagate row_now so SOF's combinational override
                // (row_now = sof ? 0 : pixel_row) actually persists past
                // the SOF cycle. Without this, pixel_row retains its
                // last-frame value (~1080) and 2nd+ runs process every
                // pixel as if in the last RU-row. Bug found by RDO
                // integrator; see project_ns_control_pixel_row_reset.md
                pixel_row <= row_now;
            end
        end else begin
            swap <= 1'b0;
        end
    end

endmodule