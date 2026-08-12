`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: pc_line_buffer  (2-clock latency, 2-phase BRAM write)
//
// Architecture:
//   6 BRAMs (bram0..5) - circular delay lines, one per delayed row.
//
//   Phase 0 (valid_in=1):
//     Read all 6 BRAMs at wr_ptr  →  rd0..rd5 (registered, appear next clock)
//     Write bram0[wr_ptr] = pixel_in
//
//   Phase 1 (valid_d1=1, one clock after Phase 0):
//     Write bram1[wr_ptr_d1] = rd0   (P[R-1][C])
//     Write bram2[wr_ptr_d1] = rd1   (P[R-2][C])
//     ...
//     Write bram5[wr_ptr_d1] = rd4   (P[R-5][C])
//     Shift column SR with pixel_d1, rd0..rd5 - all aligned to column C.
//
//   Because every BRAM is read at the SAME address (wr_ptr) in Phase 0,
//   their outputs are column-aligned with zero skew.
//   No skew-compensation FFs are needed (saves ~288 FFs vs the chained design).
//
//   BRAM contents immediately before a Phase-0 read at row R, column C:
//     bram0[C] = P[R-1][C]    (overwritten to P[R][C] during this Phase 0)
//     bram1[C] = P[R-2][C]
//     bram2[C] = P[R-3][C]
//     bram3[C] = P[R-4][C]
//     bram4[C] = P[R-5][C]
//     bram5[C] = P[R-6][C]
//   So rd0..rd5 at Phase 1 = P[R-1..6][C].  pixel_d1 = P[R][C].
//   All 7 rows aligned with zero correction needed.
//
//   Column shift register (shifts on valid_d1):
//     sr[r][c] = P[R-r][C-c]
//     r=0, c=0 = newest pixel (P[R][C])
//     r=6, c=6 = oldest pixel (P[R-6][C-6])
//
//   Output convention (same as before - mac_engine is unchanged):
//     pixels_flat[(r*7+c)*DATA_W +: DATA_W] = sr[r][c] = P[R-r][C-c]
//     pixels_flat is a combinational wire from sr[][] (saves 392 FFs).
//
//   Latency: 2 clocks from pixel_in arrival to valid pixels_flat / valid_out.
//   (vs 7 clocks in the old skew-compensation design)
//
// Resource estimate (MAX_W=1920, DATA_W=8):
//   6  BRAM18   (one per delay line, 1920x8)
//   392 FFs     (7x7 column SR)
//   ~80 FFs     (rd0-5, delay regs, counters, wr_ptrs)
//   ~50 LUTs    (valid generation, address comparators)
//   0  DSPs
//   0  skew-compensation FFs
//////////////////////////////////////////////////////////////////////////////////
module pc_line_buffer #(
    parameter MAX_W  = 1920,
    parameter DATA_W = 8
)(
    input  wire                   clk,
    input  wire                   resetn,
    input  wire                   valid_in,
    input  wire [DATA_W-1:0]      pixel_in,
    input  wire [10:0]            img_width,
    input  wire [10:0]            img_height,
    output wire [49*DATA_W-1:0]   pixels_flat,
    output reg                    valid_out
);

localparam ADDR_W = $clog2(MAX_W);

// ── Write pointers ─────────────────────────────────────────────────────────
// wr_ptr    : Phase 0 address (advances with valid_in)
// wr_ptr_d1 : Phase 1 address = wr_ptr delayed one valid_in clock
reg [ADDR_W-1:0] wr_ptr;
reg [ADDR_W-1:0] wr_ptr_d1;

always @(posedge clk) begin
    if (!resetn) begin
        wr_ptr    <= {ADDR_W{1'b0}};
        wr_ptr_d1 <= {ADDR_W{1'b0}};
    end else if (valid_in) begin
        wr_ptr    <= (wr_ptr == img_width - 1'b1) ? {ADDR_W{1'b0}} : wr_ptr + 1'b1;
        wr_ptr_d1 <= wr_ptr;
    end
end

// ── Phase-1 delay signals ──────────────────────────────────────────────────
reg              valid_d1;
reg [DATA_W-1:0] pixel_d1;

always @(posedge clk) begin
    if (!resetn) begin
        valid_d1 <= 1'b0;
        pixel_d1 <= {DATA_W{1'b0}};
    end else begin
        valid_d1 <= valid_in;
        pixel_d1 <= pixel_in;
    end
end

// ── 6 BRAM circular delay lines ────────────────────────────────────────────
// bram0: Read-First at wr_ptr (reads old P[R-1][C]), then write P[R][C].
//        Vivado infers as a single-port BRAM in Read-First mode.
//
// bram1..5: read at wr_ptr (Phase 0), write at wr_ptr_d1 (Phase 1).
//           wr_ptr != wr_ptr_d1 always (differ by 1), so no read/write
//           address collision. Vivado infers as Simple Dual-Port BRAMs.
(* ram_style = "block" *) reg [DATA_W-1:0] bram0 [0:MAX_W-1];
(* ram_style = "block" *) reg [DATA_W-1:0] bram1 [0:MAX_W-1];
(* ram_style = "block" *) reg [DATA_W-1:0] bram2 [0:MAX_W-1];
(* ram_style = "block" *) reg [DATA_W-1:0] bram3 [0:MAX_W-1];
(* ram_style = "block" *) reg [DATA_W-1:0] bram4 [0:MAX_W-1];
(* ram_style = "block" *) reg [DATA_W-1:0] bram5 [0:MAX_W-1];

// Registered Phase-0 read outputs (available one clock later = Phase 1)
reg [DATA_W-1:0] rd0, rd1, rd2, rd3, rd4, rd5;

always @(posedge clk) begin
    // Phase 0: read all BRAMs at wr_ptr; write bram0
    if (valid_in) begin
        bram0[wr_ptr] <= pixel_in;   // write P[R][C]
        rd0 <= bram0[wr_ptr];        // reads OLD value = P[R-1][C]
        rd1 <= bram1[wr_ptr];        // P[R-2][C]
        rd2 <= bram2[wr_ptr];        // P[R-3][C]
        rd3 <= bram3[wr_ptr];        // P[R-4][C]
        rd4 <= bram4[wr_ptr];        // P[R-5][C]
        rd5 <= bram5[wr_ptr];        // P[R-6][C]
    end
    // Phase 1: write bram1-5 with Phase-0 read data at wr_ptr_d1
    if (valid_d1) begin
        bram1[wr_ptr_d1] <= rd0;
        bram2[wr_ptr_d1] <= rd1;
        bram3[wr_ptr_d1] <= rd2;
        bram4[wr_ptr_d1] <= rd3;
        bram5[wr_ptr_d1] <= rd4;
        // rd5 feeds sr[6][0] directly - no bram6 needed
    end
end

// ── 7x7 column shift register ─────────────────────────────────────────────
// Shifts on valid_d1 (Phase 1) when all 7 row signals are column-aligned.
//   sr[r][c] = P[R-r][C-c]
//   sr[0][0] = P[R][C]      newest pixel
//   sr[6][6] = P[R-6][C-6] oldest pixel
reg [DATA_W-1:0] sr [0:6][0:6];

integer r, c;
always @(posedge clk) begin
    if (valid_d1) begin
        for (r = 0; r <= 6; r = r + 1)
            for (c = 6; c >= 1; c = c - 1)
                sr[r][c] <= sr[r][c-1];
        sr[0][0] <= pixel_d1;
        sr[1][0] <= rd0;
        sr[2][0] <= rd1;
        sr[3][0] <= rd2;
        sr[4][0] <= rd3;
        sr[5][0] <= rd4;
        sr[6][0] <= rd5;
    end
end

// ── pixels_flat: combinational wire from sr[][] ────────────────────────────
// pixels_flat[(r*7+c)*DATA_W +: DATA_W] = sr[r][c] = P[R-r][C-c]
// Downstream mac_engine samples this combinatorial bus on the posedge where
// valid_out is high - SR was updated on that same posedge (setup satisfied
// because sr[] FFs drive the wire; old values are sampled by downstream FFs).
genvar grf, gcf;
generate
    for (grf = 0; grf < 7; grf = grf + 1) begin : gen_row
        for (gcf = 0; gcf < 7; gcf = gcf + 1) begin : gen_col
            assign pixels_flat[(grf*7+gcf)*DATA_W +: DATA_W] = sr[grf][gcf];
        end
    end
endgenerate

// ── Row / column counters ──────────────────────────────────────────────────
// Track pixel_in position (Phase 0).  Used to gate valid_out.
reg [10:0] col_cnt, row_cnt;

always @(posedge clk) begin
    if (!resetn) begin
        col_cnt <= 11'd0;
        row_cnt <= 11'd0;
    end else if (valid_in) begin
        if (col_cnt == img_width - 1'b1) begin
            col_cnt <= 11'd0;
            row_cnt <= (row_cnt == img_height - 1'b1) ? 11'd0 : row_cnt + 1'b1;
        end else begin
            col_cnt <= col_cnt + 1'b1;
        end
    end
end

// ── Valid output ───────────────────────────────────────────────────────────
// raw_valid: pixel_in completes a valid 7x7 window (row>=6, col>=6).
// valid_out: raw_valid delayed 2 clocks to align with Phase-1 SR update.
//
// Why 2 clocks, not 1?
//   Clock T  : valid_in=1, P[R][C] arrives → raw_valid=1
//              pixel_d1 ← pixel_in = P[R][C]   (registered)
//              SR shifts with OLD pixel_d1 = P[R][C-1]   ← still 1 behind
//   Clock T+1: SR shifts with pixel_d1 = P[R][C]  ← correct data in sr[0][0]
//              valid_out fires here (2nd register stage)
//   Downstream latches pixels_flat and valid_out at T+1 posedge.
wire raw_valid = (row_cnt >= 11'd6) && (col_cnt >= 11'd6) && valid_in;
reg  raw_valid_r;

always @(posedge clk) begin
    if (!resetn) begin
        raw_valid_r <= 1'b0;
        valid_out   <= 1'b0;
    end else begin
        raw_valid_r <= raw_valid;
        valid_out   <= raw_valid_r;
    end
end

endmodule