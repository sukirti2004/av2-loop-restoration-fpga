`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_hr_delay_line.v
//
// Self-checking testbench for hr_delay_line.v. Instantiates 3 DUTs in one
// sim so one run covers all delay values the RDO combiner will use:
//   dut0: DELAY=0  (passthrough, for NONE candidate)
//   dut6: DELAY=6  (matches PC pipeline latency)
//   dut7: DELAY=7  (matches NS pipeline latency)
//
// Coverage:
//   T1. Reset behavior — outputs are 0 immediately after reset.
//   T2. Passthrough (DELAY=0) — hr_out follows hr_in same cycle, valid_out
//       follows valid_in same cycle.
//   T3. Fixed-latency (DELAY=6) — hr_out shows hr_in from exactly 6 cycles ago.
//   T4. Fixed-latency (DELAY=7) — hr_out shows hr_in from exactly 7 cycles ago.
//   T5. Bubble propagation — valid_in=0 for one cycle produces valid_out=0
//       exactly DELAY cycles later (for the DELAY=6 DUT).
//   T6. Distinct-value pipeline test — drive a walking sequence, verify each
//       output pixel exactly matches the input pixel from DELAY cycles ago.
// -----------------------------------------------------------------------------

module tb_hr_delay_line;

    // ----- DUT-common inputs -----
    reg        clk;
    reg        rst;
    reg        valid_in;
    reg  [7:0] hr_in;

    // ----- DUT0: DELAY=0 (passthrough) -----
    wire       valid_out0;
    wire [7:0] hr_out0;
    hr_delay_line #(.DELAY(0)) dut0 (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .hr_in(hr_in),
        .valid_out(valid_out0), .hr_out(hr_out0)
    );

    // ----- DUT6: DELAY=6 -----
    wire       valid_out6;
    wire [7:0] hr_out6;
    hr_delay_line #(.DELAY(6)) dut6 (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .hr_in(hr_in),
        .valid_out(valid_out6), .hr_out(hr_out6)
    );

    // ----- DUT7: DELAY=7 -----
    wire       valid_out7;
    wire [7:0] hr_out7;
    hr_delay_line #(.DELAY(7)) dut7 (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .hr_in(hr_in),
        .valid_out(valid_out7), .hr_out(hr_out7)
    );

    // ----- Bookkeeping -----
    integer err_count;
    integer test_num;
    integer i;

    // ----- Recording of driven history (for T6 correctness check) -----
    // Circular buffer of the last 64 driven (hr_in, valid_in) pairs.
    // Ample for the max DELAY of 7 tested here.
    reg  [7:0] hist_pixel [0:63];
    reg        hist_valid [0:63];
    integer    hist_wr;   // next write index

    // ----- Clock: 100 MHz -----
    always #5 clk = ~clk;

    // ----- Helper: drive one pixel-cycle and record it -----
    task automatic drive_cycle(input [7:0] px, input v);
        begin
            @(negedge clk);
            hr_in    = px;
            valid_in = v;
            // Record what we drove — hist_wr advances after the DUTs sample
            // this pixel at the coming posedge.
            hist_pixel[hist_wr] = px;
            hist_valid[hist_wr] = v;
            hist_wr             = (hist_wr + 1) % 64;
        end
    endtask

    // ----- Helper: fetch what we drove N cycles ago (relative to most recent) -----
    // For DELAY=D DUT, the current output should equal the (D+1)-th most
    // recent drive (i.e., cycles_ago = D+1 from the head write position,
    // sampled after the DUT has had one clock to register it).
    task automatic history_at(
        input integer cycles_ago,
        output [7:0]  px,
        output        v
    );
        integer idx;
        begin
            idx = (hist_wr - cycles_ago + 64) % 64;
            px  = hist_pixel[idx];
            v   = hist_valid[idx];
        end
    endtask

    // ----- Helper: reset the DUTs -----
    task automatic do_reset;
        begin
            @(negedge clk);
            rst      = 1'b1;
            valid_in = 1'b0;
            hr_in    = 8'd0;
            hist_wr  = 0;
            @(posedge clk);
            @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    // =========================================================================
    // MAIN
    // =========================================================================
    initial begin
        clk       = 1'b0;
        rst       = 1'b1;
        valid_in  = 1'b0;
        hr_in     = 8'd0;
        err_count = 0;
        test_num  = 0;
        hist_wr   = 0;

        // Bring out of reset
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ---------------------------------------------------------------------
        // T1. Reset behavior — sample outputs shortly after reset release.
        // ---------------------------------------------------------------------
        test_num = 1;
        @(negedge clk);
        // DUT0 passthrough: outputs mirror driven inputs (both 0 here)
        if (hr_out0 === 8'd0 && valid_out0 === 1'b0 &&
            hr_out6 === 8'd0 && valid_out6 === 1'b0 &&
            hr_out7 === 8'd0 && valid_out7 === 1'b0) begin
            $display("[T1] PASS reset_state : all outputs 0");
        end else begin
            $display("[T1] FAIL reset_state : dut0=(px=%0d,v=%0b) dut6=(px=%0d,v=%0b) dut7=(px=%0d,v=%0b)",
                     hr_out0, valid_out0, hr_out6, valid_out6, hr_out7, valid_out7);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T2. Passthrough (DELAY=0) — hr_out0 must equal hr_in same cycle.
        // Drive a single pixel and check dut0 immediately.
        // ---------------------------------------------------------------------
        test_num = 2;
        do_reset;
        drive_cycle(8'd123, 1'b1);
        // dut0 is combinational passthrough — check on the same negedge we drove.
        // hr_out0/valid_out0 update immediately when hr_in/valid_in change.
        #1;   // tiny delay to let combinational outputs settle
        if (hr_out0 === 8'd123 && valid_out0 === 1'b1) begin
            $display("[T2] PASS passthrough_dut0 : hr_out0=%0d valid_out0=%0b (same cycle)",
                     hr_out0, valid_out0);
        end else begin
            $display("[T2] FAIL passthrough_dut0 : hr_out0=%0d valid_out0=%0b (expected 123, 1)",
                     hr_out0, valid_out0);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T3. Fixed-latency DELAY=6.
        // Drive pixel 200 at cycle 0, then bubbles, and confirm dut6 emits 200
        // exactly 6 cycles later.
        // ---------------------------------------------------------------------
        test_num = 3;
        do_reset;
        drive_cycle(8'd200, 1'b1);       // cycle 0: driven, valid=1
        // Now drive 5 more bubble cycles; dut6 should still be 0 (delay=6)
        for (i = 0; i < 5; i = i + 1) drive_cycle(8'd0, 1'b0);
        // Sample dut6 on the negedge after 6 total drive cycles — expect 200
        @(negedge clk);
        if (hr_out6 === 8'd200 && valid_out6 === 1'b1) begin
            $display("[T3] PASS delay6_hit : hr_out6=%0d valid_out6=%0b at +6",
                     hr_out6, valid_out6);
        end else begin
            $display("[T3] FAIL delay6_hit : hr_out6=%0d valid_out6=%0b (expected 200, 1)",
                     hr_out6, valid_out6);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T4. Fixed-latency DELAY=7. Same shape as T3 but +1 cycle.
        // ---------------------------------------------------------------------
        test_num = 4;
        do_reset;
        drive_cycle(8'd77, 1'b1);        // cycle 0: driven, valid=1
        for (i = 0; i < 6; i = i + 1) drive_cycle(8'd0, 1'b0);
        @(negedge clk);
        if (hr_out7 === 8'd77 && valid_out7 === 1'b1) begin
            $display("[T4] PASS delay7_hit : hr_out7=%0d valid_out7=%0b at +7",
                     hr_out7, valid_out7);
        end else begin
            $display("[T4] FAIL delay7_hit : hr_out7=%0d valid_out7=%0b (expected 77, 1)",
                     hr_out7, valid_out7);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T5. Bubble propagation on the DELAY=6 DUT.
        //
        // Drive exactly 6 distinct pixels (drives #1..#6), one of which is a
        // bubble at drive #2. Then advance the sim by extra clock cycles
        // WITHOUT calling drive_cycle again — the pipeline naturally walks
        // drives #1, #2, #3, ... out of pipe[5] one clock at a time.
        //
        // Timing:
        //   drive_cycle sets signals at negedge; DUT samples at next posedge.
        //   Each drive_cycle advances one full clock period.
        //   After 6 drives, we're at negedge N6. After @(negedge), we're at N7
        //   having passed through posedge P7. pipe[5] at end of P7 = drive #1.
        //   Each further @(negedge) shifts one drive out of pipe[5].
        // ---------------------------------------------------------------------
        test_num = 5;
        do_reset;
        drive_cycle(8'd10,  1'b1);   // drive #1
        drive_cycle(8'd0,   1'b0);   // drive #2 (bubble)
        drive_cycle(8'd30,  1'b1);   // drive #3
        drive_cycle(8'd40,  1'b1);   // drive #4
        drive_cycle(8'd50,  1'b1);   // drive #5
        drive_cycle(8'd60,  1'b1);   // drive #6

        // Advance one more clock → pipe[5] presents drive #1 = (10, 1)
        @(negedge clk);
        if (hr_out6 === 8'd10 && valid_out6 === 1'b1) begin
            $display("[T5] PASS bubble_before : dut6 = (10, 1)  [drive #1]");
        end else begin
            $display("[T5] FAIL bubble_before : dut6 = (%0d, %0b) expected (10, 1)",
                     hr_out6, valid_out6);
            err_count = err_count + 1;
        end

        // Advance one more clock → pipe[5] presents drive #2 = bubble
        @(negedge clk);
        if (valid_out6 === 1'b0) begin
            $display("[T5] PASS bubble_hit : dut6 valid_out6=0 [drive #2 bubble]");
        end else begin
            $display("[T5] FAIL bubble_hit : dut6 valid_out6=%0b (expected 0)",
                     valid_out6);
            err_count = err_count + 1;
        end

        // Advance one more clock → pipe[5] presents drive #3 = (30, 1)
        @(negedge clk);
        if (hr_out6 === 8'd30 && valid_out6 === 1'b1) begin
            $display("[T5] PASS bubble_after : dut6 = (30, 1)  [drive #3]");
        end else begin
            $display("[T5] FAIL bubble_after : dut6 = (%0d, %0b) expected (30, 1)",
                     hr_out6, valid_out6);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T6. Distinct-value pipeline test — 20 cycles of walking values,
        // verify at every step that dut6 output equals what we drove 6 back,
        // and dut7 output equals what we drove 7 back. Uses the history
        // buffer to compute expected values.
        //
        // NOTE: only `drive_cycle` per iteration, no extra @(negedge). Each
        // drive_cycle already advances one full clock period; adding
        // @(negedge) would double the cycle count and drift the check.
        //
        // Timing:
        //   At end of iteration i (0-indexed), we're at negedge N_{i+1}
        //   and DUT has processed posedges P_1..P_{i+1}.
        //   pipe[5] at end of P_{i+1} = drive #(i+1-6) = drive #(i-5).
        //   That drive corresponds to iteration (i-6), i.e. history[i-6].
        //   history_at(cycles_ago=7) returns history[hist_wr-7] = history[i-6]. ✓
        //   Similarly for dut7 (DELAY=7): drive #(i-6) at iteration (i-7),
        //   history_at(8) → history[i-7]. ✓
        // ---------------------------------------------------------------------
        test_num = 6;
        do_reset;
        begin : t6_check
            reg [7:0] exp_px6, exp_px7;
            reg       exp_v6,  exp_v7;
            integer   errs_t6;
            errs_t6 = 0;
            for (i = 0; i < 20; i = i + 1) begin
                drive_cycle((i * 13 + 7) & 8'hFF, (i != 5 && i != 12));   // 2 bubbles at i=5, 12
                if (i >= 6) begin
                    history_at(7, exp_px6, exp_v6);
                    if (hr_out6 !== exp_px6 || valid_out6 !== exp_v6) begin
                        $display("[T6] FAIL dut6 at step %0d: got (%0d, %0b) expected (%0d, %0b)",
                                 i, hr_out6, valid_out6, exp_px6, exp_v6);
                        errs_t6 = errs_t6 + 1;
                    end
                end
                if (i >= 7) begin
                    history_at(8, exp_px7, exp_v7);
                    if (hr_out7 !== exp_px7 || valid_out7 !== exp_v7) begin
                        $display("[T6] FAIL dut7 at step %0d: got (%0d, %0b) expected (%0d, %0b)",
                                 i, hr_out7, valid_out7, exp_px7, exp_v7);
                        errs_t6 = errs_t6 + 1;
                    end
                end
            end
            if (errs_t6 == 0) begin
                $display("[T6] PASS walking_pattern_20_cycles : dut6 and dut7 tracked correctly");
            end else begin
                $display("[T6] FAIL walking_pattern_20_cycles : %0d step(s) mismatched", errs_t6);
                err_count = err_count + errs_t6;
            end
        end

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("");
        $display("==========================================================");
        if (err_count == 0) begin
            $display(" ALL TESTS PASSED ");
        end else begin
            $display(" %0d TEST(S) FAILED ", err_count);
        end
        $display("==========================================================");
        #10 $finish;
    end

    // ----- Global timeout -----
    initial begin
        #100000;
        $display("ERROR: Global timeout — testbench never reached $finish");
        $finish;
    end

endmodule
