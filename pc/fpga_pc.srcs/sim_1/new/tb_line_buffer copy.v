`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_line_buffer
//
// Sends a 10×10 raster of pixels (value = row*10 + col) and checks:
//   Test 1 - First valid patch content
//   Test 2 - Total valid patch count (should be 4×4 = 16)
//
// FIX 1 (expected values):
//   line_buffer convention: pixels_flat[(r*7+c)*8 +: 8] = sr[r][c]
//   where r=0,c=0 is the NEWEST pixel (P[6][6] for the first window)
//   and   r=6,c=6 is the OLDEST pixel (P[0][0]).
//   So expected[(r*7+c)*8 +: 8] = (6-r)*10 + (6-c).
//
// FIX 2 (pipeline flush):
//   The 7-stage vld_pipe only advances when valid_in=1.
//   After the last pixel (#99 = P[9][9]), raw_valid pulses for the last
//   row (P[9][6..9]) are still propagating.  7 extra valid_in=1 clocks
//   flush them so all 16 patches fire before wait(valid_count >= 16).
//////////////////////////////////////////////////////////////////////////////////
module tb_line_buffer;

// ─────────────────────────────────────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────────────────────────────────────
parameter IMG_W = 10;
parameter IMG_H = 10;
parameter MAX_W = 11'd1920;

// ─────────────────────────────────────────────────────────────────────────────
// DUT I/O
// ─────────────────────────────────────────────────────────────────────────────
reg        clk, resetn, valid_in;
reg  [7:0] pixel_in;

wire              valid_out;
wire [49*8-1:0]   pixels_flat;

line_buffer #(.MAX_W(MAX_W)) dut (
    .clk        (clk),
    .resetn     (resetn),
    .valid_in   (valid_in),
    .img_width  (11'd10),
    .pixel_in   (pixel_in),
    .valid_out  (valid_out),
    .pixels_flat(pixels_flat)
);

// ─────────────────────────────────────────────────────────────────────────────
// Clock  (10 ns period = 100 MHz)
// ─────────────────────────────────────────────────────────────────────────────
initial clk = 0;
always #5 clk = ~clk;

// ─────────────────────────────────────────────────────────────────────────────
// Monitor - fires on every posedge, so it catches every valid_out pulse
// regardless of pipeline depth.
// ─────────────────────────────────────────────────────────────────────────────
// Pixel loop variables (initial block only)
integer r, c;
// Monitor loop variables - SEPARATE from r,c to avoid corrupting the pixel loop
integer er, ec;

reg [49*8-1:0] expected;

// Use reg (not integer) so wait() works reliably in XSim
reg [7:0] valid_count;
reg [7:0] errors;

initial begin
    valid_count = 0;
    errors      = 0;
end

always @(posedge clk) begin : monitor
    #1; // sample just after posedge
    if (valid_out) begin
        valid_count = valid_count + 1;

        // ── Test 1: check the first valid patch ──────────────────────────────
        if (valid_count == 1) begin
            // Build expected using line_buffer's output convention:
            //   pixels_flat[(r*7+c)*8 +: 8] = sr[r][c] = P[6-r][6-c]
            //   (er=0,ec=0 is newest = P[6][6]; er=6,ec=6 is oldest = P[0][0])
            for (er = 0; er < 7; er = er + 1)
                for (ec = 0; ec < 7; ec = ec + 1)
                    expected[(er*7+ec)*8 +: 8] = (6-er)*10 + (6-ec);

            if (pixels_flat === expected) begin
                $display("PASS Test 1: first 7x7 patch matches P[6..0][6..0]");
            end else begin
                $display("FAIL Test 1: patch mismatch");
                $display("       pixels_flat[sr[0][0]] = %3d  (expected %3d = P[6][6])",
                         pixels_flat[7:0],            (6-0)*10+(6-0));
                $display("       pixels_flat[sr[0][6]] = %3d  (expected %3d = P[6][0])",
                         pixels_flat[6*8+7 -: 8],     (6-0)*10+(6-6));
                $display("       pixels_flat[sr[6][0]] = %3d  (expected %3d = P[0][6])",
                         pixels_flat[42*8+7 -: 8],    (6-6)*10+(6-0));
                $display("       pixels_flat[sr[6][6]] = %3d  (expected %3d = P[0][0])",
                         pixels_flat[48*8+7 -: 8],    0);
                errors = errors + 1;
            end
        end
    end
end

// ─────────────────────────────────────────────────────────────────────────────
// Stimulus
// ─────────────────────────────────────────────────────────────────────────────
initial begin
    $display("=== tb_line_buffer ===");

    // Reset
    resetn   = 0;
    valid_in = 0;
    pixel_in = 0;
    repeat(4) @(posedge clk);
    @(negedge clk); resetn = 1;

    // ── Send 10×10 raster (pixel value = row*10 + col) ───────────────────────
    for (r = 0; r < IMG_H; r = r + 1)
        for (c = 0; c < IMG_W; c = c + 1) begin
            @(negedge clk);
            pixel_in = r * 10 + c;
            valid_in = 1;
        end

    // ── Flush the 7-stage vld_pipe ────────────────────────────────────────────
    // After pixel #99 (P[9][9]) the last 4 raw_valid pulses (row 9, cols 6-9)
    // are still in the pipeline.  They need 7 more valid_in=1 clocks to reach
    // valid_out.  Dummy pixel_in values don't affect the patch-count test.
    repeat(7) begin
        @(negedge clk);
        pixel_in = 8'd0; // dummy
        valid_in = 1;
    end
    @(negedge clk); valid_in = 0;

    // ── Wait for all 16 patches to arrive ────────────────────────────────────
    wait(valid_count >= 16);

    // ── Test 2: patch count ───────────────────────────────────────────────────
    // (10-7+1) x (10-7+1) = 4x4 = 16
    if (valid_count == 16) begin
        $display("PASS Test 2: exactly 16 valid patches produced");
    end else begin
        $display("FAIL Test 2: expected 16 patches, got %0d", valid_count);
        errors = errors + 1;
    end

    // ── Summary ───────────────────────────────────────────────────────────────
    #10;
    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("%0d TEST(S) FAILED", errors);

    $finish;
end

endmodule