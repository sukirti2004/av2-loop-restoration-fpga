`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: line_buffer
// Description:
//   Sliding 7x7 window extractor for the PC filter pipeline.
//
//   Architecture (standard FPGA line buffer):
//     6 BRAM circular delay lines  - one per row of delay (rows 1..6)
//     6 skew-compensation FF pipes - re-aligns rows to same column offset
//     7x7 column shift registers   - holds current 7-column window per row
//
//   Resource cost (target):
//     ~6 BRAM18  (was 0 BRAM, 108k FFs, 413k LUTs with register array)
//     ~1000 FFs
//     ~100 LUTs
//
//   BRAM Read-First mode:
//     Each BRAM is a circular buffer of depth MAX_W.
//     Write at wr_ptr; simultaneously read the OLD value at wr_ptr.
//     Because wr_ptr wraps every img_width clocks, the old value is
//     exactly img_width clocks old = 1 full row back. This gives 1-row delay per BRAM.
//
//   Column skew:
//     BRAM registered read has 1-cycle latency, so each chained stage
//     is 1 clock (= 1 column) later than the previous stage.
//     Stage k output arrives at clock T+k+1 for pixel_in at clock T.
//     Skew-compensation delay pipes add (5-k) extra FF stages so that
//     all rows are aligned at exactly T+6, representing column C.
//
//   Output:
//     pixels_flat[(r*7+c)*8 +: 8] = pixel at row-offset r, col-offset c
//     r=0,c=0 is the most-recent pixel; r=6,c=6 is the oldest.
//     valid_out pulses one cycle after a complete 7x7 window is ready.
//////////////////////////////////////////////////////////////////////////////////
module line_buffer #(
    parameter MAX_W = 1920
)(
    input  wire             clk,
    input  wire             resetn,
    input  wire             valid_in,
    input  wire [7:0]       pixel_in,
    input  wire [10:0]      img_width,
    input  wire [10:0]      img_height,
    output reg  [49*8-1:0]  pixels_flat,
    output reg              valid_out
);

// ── Write pointer (column address for all BRAMs) ───────────────────────────
// Advances each valid_in, wraps at img_width.
reg [10:0] wr_ptr;
always @(posedge clk) begin
    if (!resetn)
        wr_ptr <= 0;
    else if (valid_in)
        wr_ptr <= (wr_ptr == img_width - 1) ? 11'd0 : wr_ptr + 11'd1;
end

// ── 6 BRAM circular delay lines ───────────────────────────────────────────
// Each BRAM: depth=MAX_W, width=8.
// Write new pixel at wr_ptr; read the OLD value at wr_ptr (Read-First mode).
// The old value = pixel written img_width clocks ago = 1 row back.
// BRAMs are chained: bram0 input = pixel_in, bram1 input = row_d0, etc.
//
// Timing: row_d[k] at clock T+k+1 = P[R-(k+1)][C]
// (k+1 cycles late because of k+1 BRAM register stages in the chain)
(* ram_style = "block" *) reg [7:0] bram0 [0:MAX_W-1];
(* ram_style = "block" *) reg [7:0] bram1 [0:MAX_W-1];
(* ram_style = "block" *) reg [7:0] bram2 [0:MAX_W-1];
(* ram_style = "block" *) reg [7:0] bram3 [0:MAX_W-1];
(* ram_style = "block" *) reg [7:0] bram4 [0:MAX_W-1];
(* ram_style = "block" *) reg [7:0] bram5 [0:MAX_W-1];

reg [7:0] row_d0, row_d1, row_d2, row_d3, row_d4, row_d5;

always @(posedge clk) begin
    if (valid_in) begin
        // Stage 0: 1 row delay
        bram0[wr_ptr] <= pixel_in;   row_d0 <= bram0[wr_ptr];
        // Stage 1: 2 rows delay (write previous row_d0)
        bram1[wr_ptr] <= row_d0;     row_d1 <= bram1[wr_ptr];
        // Stage 2: 3 rows delay
        bram2[wr_ptr] <= row_d1;     row_d2 <= bram2[wr_ptr];
        // Stage 3: 4 rows delay
        bram3[wr_ptr] <= row_d2;     row_d3 <= bram3[wr_ptr];
        // Stage 4: 5 rows delay
        bram4[wr_ptr] <= row_d3;     row_d4 <= bram4[wr_ptr];
        // Stage 5: 6 rows delay
        bram5[wr_ptr] <= row_d4;     row_d5 <= bram5[wr_ptr];
    end
end

// ── Skew-compensation delay pipes ─────────────────────────────────────────
// row_d[k] is (k+1) clocks late relative to pixel_in.
// We want all 7 row signals aligned at T+6 (6 clocks after pixel_in).
//   comp[0] = pixel_in delayed 6 clocks
//   comp[1] = row_d0    delayed 5 clocks  (row_d0 arrives 1 clock late)
//   comp[2] = row_d1    delayed 4 clocks
//   comp[3] = row_d2    delayed 3 clocks
//   comp[4] = row_d3    delayed 2 clocks
//   comp[5] = row_d4    delayed 1 clock
//   comp[6] = row_d5    delayed 0 clocks  (already 6 clocks late)

reg [7:0] dp0_0, dp0_1, dp0_2, dp0_3, dp0_4, dp0_5; // pixel_in  → 6-stage pipe
reg [7:0] dp1_0, dp1_1, dp1_2, dp1_3, dp1_4;         // row_d0   → 5-stage pipe
reg [7:0] dp2_0, dp2_1, dp2_2, dp2_3;                 // row_d1   → 4-stage pipe
reg [7:0] dp3_0, dp3_1, dp3_2;                         // row_d2   → 3-stage pipe
reg [7:0] dp4_0, dp4_1;                                // row_d3   → 2-stage pipe
reg [7:0] dp5_0;                                       // row_d4   → 1-stage pipe

always @(posedge clk) begin
    if (valid_in) begin
        dp0_0<=pixel_in; dp0_1<=dp0_0; dp0_2<=dp0_1; dp0_3<=dp0_2; dp0_4<=dp0_3; dp0_5<=dp0_4;
        dp1_0<=row_d0;   dp1_1<=dp1_0; dp1_2<=dp1_1; dp1_3<=dp1_2; dp1_4<=dp1_3;
        dp2_0<=row_d1;   dp2_1<=dp2_0; dp2_2<=dp2_1; dp2_3<=dp2_2;
        dp3_0<=row_d2;   dp3_1<=dp3_0; dp3_2<=dp3_1;
        dp4_0<=row_d3;   dp4_1<=dp4_0;
        dp5_0<=row_d4;
    end
end

// Aligned row data - all represent P[R-r][C] at clock T+6
wire [7:0] comp [0:6];
assign comp[0] = dp0_5;   // P[R][C],   6 clocks delayed
assign comp[1] = dp1_4;   // P[R-1][C], 6 clocks total (1 BRAM + 5 FF)
assign comp[2] = dp2_3;   // P[R-2][C]
assign comp[3] = dp3_2;   // P[R-3][C]
assign comp[4] = dp4_1;   // P[R-4][C]
assign comp[5] = dp5_0;   // P[R-5][C]
assign comp[6] = row_d5;  // P[R-6][C], 6 BRAM stages = 6 clocks

// ── 7x7 column shift registers ────────────────────────────────────────────
// sr[r][0] = most recent pixel for row r (= comp[r] this clock)
// sr[r][c] = pixel c clocks ago for row r = P[R-r][C-c]
// Together: sr[r][c] = P[R-r][C-c] - the full 7x7 sliding window.
reg [7:0] sr [0:6][0:6];

integer r, c;
always @(posedge clk) begin
    if (valid_in) begin
        for (r = 0; r <= 6; r = r+1) begin
            sr[r][6] <= sr[r][5];
            sr[r][5] <= sr[r][4];
            sr[r][4] <= sr[r][3];
            sr[r][3] <= sr[r][2];
            sr[r][2] <= sr[r][1];
            sr[r][1] <= sr[r][0];
            sr[r][0] <= comp[r];
        end
    end
end

// ── Row/column counters for valid generation ───────────────────────────────
// Track position of pixel_in (NOT of the delayed comp[] signals).
// valid_out is triggered when the ORIGINAL pixel's position had row>=6, col>=6,
// delayed by 6+1=7 clocks to match the comp[]+sr pipeline depth.
//   +6 for the compensation delay
//   +1 for the final output register

reg [10:0] col_cnt, row_cnt;
always @(posedge clk) begin
    if (!resetn) begin
        col_cnt <= 0;
        row_cnt <= 0;
    end else if (valid_in) begin
        if (col_cnt == img_width - 1) begin
            col_cnt <= 0;
            if (row_cnt == img_height - 1)
                row_cnt <= 0;
            else
                row_cnt <= row_cnt + 1;
        end else
            col_cnt <= col_cnt + 1;
    end
end

// 7-bit shift register: delays (row>=6 && col>=6) condition by 7 clocks
wire raw_valid = (row_cnt >= 11'd6) && (col_cnt >= 11'd6) && valid_in;

reg [6:0] vld_pipe;
always @(posedge clk) begin
    if (!resetn)
        vld_pipe <= 7'b0;
    else if (valid_in)
        vld_pipe <= {vld_pipe[5:0], raw_valid};
end

// ── Output ─────────────────────────────────────────────────────────────────
// Register pixels_flat and valid_out together (adds the final +1 clock).
integer rf, cf;
always @(posedge clk) begin
    if (!resetn) begin
        valid_out   <= 1'b0;
        pixels_flat <= {(49*8){1'b0}};
    end else if (valid_in) begin
        valid_out <= vld_pipe[6];
        if (vld_pipe[6]) begin
            for (rf = 0; rf <= 6; rf = rf+1)
                for (cf = 0; cf <= 6; cf = cf+1)
                    pixels_flat[(rf*7+cf)*8 +: 8] <= sr[rf][cf];
        end
    end else begin
        valid_out <= 1'b0;
    end
end

endmodule