`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_mse_accumulator.v
//
// Self-checking testbench for mse_accumulator.v. Covers:
//   T1. Reset behavior
//   T2. All-zeros RU (mse = 0)
//   T3. Constant positive offset (16 px, cand=100, hr=90 → mse = 16·100 = 1600)
//   T4. Full-range positive diff (16 px, cand=255, hr=0 → mse = 16·65025)
//   T5. Full-range negative diff (16 px, cand=0, hr=255 → mse = 16·65025, verifies signed)
//   T6. Mixed pattern (arbitrary values, verified against reference-in-TB sum)
//   T7. Consecutive RUs (two back-to-back, independent latch and reset)
//   T8. Bubbles mid-RU (valid_in gaps must not corrupt accumulation)
//   T9. Swap timing (mse_valid fires exactly 3 clocks after swap+valid_in)
//   T10. Swap then idle (valid_in goes low right after swap, mse_valid still fires)
//
// Prints PASS/FAIL per subtest and a final summary. `$finish` at the end.
// Nonzero final err_count → exit with failure.
// -----------------------------------------------------------------------------

module tb_mse_accumulator;

    // ----- DUT signals -----
    reg         clk;
    reg         rst;
    reg         valid_in;
    reg  [7:0]  candidate_px;
    reg  [7:0]  hr_px;
    reg         swap;
    wire [32:0] mse_out;
    wire        mse_valid;

    // ----- Bookkeeping -----
    integer     err_count;
    integer     test_num;
    integer     i;
    reg  [63:0] observed_mse;   // wider than uint33 for safety
    reg  [63:0] expected_mse;

    // ----- Module-scope arrays used by T6 (Verilog-2001 forbids passing
    // unpacked arrays as task/function ports, so we hoist them here and
    // the reference task reads them directly). Sized 64 entries; only 32
    // used by T6, room for future longer tests.
    reg [7:0] cand_arr [0:63];
    reg [7:0] hr_arr   [0:63];

    // ----- Reference model result register.
    // Uses a module-scope reg instead of an output-port on the task, because
    // xvlog can mis-sign-extend `output [63:0]` when combined with signed
    // integer intermediates inside an automatic task (observed: correct DUT
    // value of 358592 vs task-returned garbage 18446732546017687744, which
    // is −11.5 trillion as signed 64-bit). Writing directly to a module-scope
    // reg sidesteps that.
    reg [63:0] ref_mse_result;

    task automatic compute_ref_mse(input integer n_pixels);
        integer    k;
        integer    c_ext;
        integer    h_ext;
        integer    diff;
        reg [31:0] sqdiff;
        begin
            ref_mse_result = 64'd0;
            for (k = 0; k < n_pixels; k = k + 1) begin
                c_ext          = cand_arr[k];             // zero-extend 8b to 32b integer
                h_ext          = hr_arr[k];
                diff           = c_ext - h_ext;            // int32 signed subtract
                sqdiff         = diff * diff;              // positive square, fits uint32
                ref_mse_result = ref_mse_result + {32'd0, sqdiff};
            end
        end
    endtask

    // ----- Clock: 100 MHz -----
    always #5 clk = ~clk;

    // ----- DUT -----
    mse_accumulator dut (
        .clk          (clk),
        .rst          (rst),
        .valid_in     (valid_in),
        .candidate_px (candidate_px),
        .hr_px        (hr_px),
        .swap         (swap),
        .mse_out      (mse_out),
        .mse_valid    (mse_valid)
    );

    // ----- Helper: drive one pixel for one clk (no swap) -----
    task automatic drive_pixel(
        input [7:0] cand,
        input [7:0] hr,
        input       is_last
    );
        begin
            @(negedge clk);
            valid_in     = 1'b1;
            candidate_px = cand;
            hr_px        = hr;
            swap         = is_last;
        end
    endtask

    // ----- Helper: drive a bubble (valid_in=0) for one clk -----
    task automatic drive_bubble;
        begin
            @(negedge clk);
            valid_in     = 1'b0;
            candidate_px = 8'd0;
            hr_px        = 8'd0;
            swap         = 1'b0;
        end
    endtask

    // ----- Helper: wait for mse_valid, capture mse_out, timeout at cycles -----
    task automatic wait_for_mse_valid(input integer max_wait_cycles);
        integer waited;
        begin
            waited = 0;
            observed_mse = 64'hDEAD_BEEF_DEAD_BEEF;
            while (!mse_valid && waited < max_wait_cycles) begin
                @(posedge clk);
                waited = waited + 1;
            end
            if (mse_valid) begin
                observed_mse = {31'd0, mse_out};
            end else begin
                $display("[T%0d]   TIMEOUT: mse_valid never fired within %0d cycles",
                         test_num, max_wait_cycles);
                err_count = err_count + 1;
            end
        end
    endtask

    // ----- Helper: check observed vs expected, print PASS/FAIL -----
    task automatic check_mse(input [255:0] label);
        begin
            if (observed_mse === expected_mse) begin
                $display("[T%0d] PASS %0s : mse = %0d", test_num, label, observed_mse);
            end else begin
                $display("[T%0d] FAIL %0s : mse = %0d (expected %0d)",
                         test_num, label, observed_mse, expected_mse);
                err_count = err_count + 1;
            end
        end
    endtask

    // ----- Helper: check mse_valid did NOT fire -----
    task automatic check_no_mse_valid(input integer wait_cycles, input [255:0] label);
        integer waited;
        reg fired;
        begin
            fired = 1'b0;
            waited = 0;
            while (waited < wait_cycles) begin
                @(posedge clk);
                if (mse_valid) fired = 1'b1;
                waited = waited + 1;
            end
            if (!fired) begin
                $display("[T%0d] PASS %0s : mse_valid stayed low as expected", test_num, label);
            end else begin
                $display("[T%0d] FAIL %0s : mse_valid fired unexpectedly", test_num, label);
                err_count = err_count + 1;
            end
        end
    endtask

    // ----- Reset the DUT -----
    task automatic do_reset;
        begin
            @(negedge clk);
            rst          = 1'b1;
            valid_in     = 1'b0;
            candidate_px = 8'd0;
            hr_px        = 8'd0;
            swap         = 1'b0;
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
        swap      = 1'b0;
        candidate_px = 8'd0;
        hr_px     = 8'd0;
        err_count = 0;
        test_num  = 0;

        // Give a couple cycles of reset before anything else.
        @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ---------------------------------------------------------------------
        // T1. Reset behavior
        // ---------------------------------------------------------------------
        test_num = 1;
        // Just after reset, mse_out and mse_valid should be 0. Give a moment for
        // any propagation.
        @(posedge clk);
        if (mse_out === 33'd0 && mse_valid === 1'b0) begin
            $display("[T1] PASS reset_state : mse_out=0, mse_valid=0");
        end else begin
            $display("[T1] FAIL reset_state : mse_out=%0d mse_valid=%0b",
                     mse_out, mse_valid);
            err_count = err_count + 1;
        end

        // ---------------------------------------------------------------------
        // T2. All-zeros RU: 16 pixels, cand=0, hr=0 → expected mse=0
        // ---------------------------------------------------------------------
        test_num = 2;
        do_reset;
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd0, 8'd0, 1'b0);
        drive_pixel(8'd0, 8'd0, 1'b1);
        drive_bubble;   // stop driving after last pixel; pipeline drains
        expected_mse = 64'd0;
        wait_for_mse_valid(10);
        check_mse("all_zeros_16px");

        // ---------------------------------------------------------------------
        // T3. Constant positive offset: 16 px, cand=100, hr=90, diff=10, sqdiff=100
        //     → expected mse = 16 · 100 = 1600
        // ---------------------------------------------------------------------
        test_num = 3;
        do_reset;
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd100, 8'd90, 1'b0);
        drive_pixel(8'd100, 8'd90, 1'b1);
        drive_bubble;
        expected_mse = 64'd1600;
        wait_for_mse_valid(10);
        check_mse("const_offset_+10_16px");

        // ---------------------------------------------------------------------
        // T4. Full-range positive diff: cand=255, hr=0, diff=255, sqdiff=65025
        //     → expected mse = 16 · 65025 = 1_040_400
        // ---------------------------------------------------------------------
        test_num = 4;
        do_reset;
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd255, 8'd0, 1'b0);
        drive_pixel(8'd255, 8'd0, 1'b1);
        drive_bubble;
        expected_mse = 64'd1040400;
        wait_for_mse_valid(10);
        check_mse("full_range_pos_16px");

        // ---------------------------------------------------------------------
        // T5. Full-range negative diff: cand=0, hr=255, diff=-255, sqdiff=65025
        //     → expected mse = 16 · 65025 = 1_040_400 (verifies signed diff)
        // ---------------------------------------------------------------------
        test_num = 5;
        do_reset;
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd0, 8'd255, 1'b0);
        drive_pixel(8'd0, 8'd255, 1'b1);
        drive_bubble;
        expected_mse = 64'd1040400;
        wait_for_mse_valid(10);
        check_mse("full_range_neg_16px");

        // ---------------------------------------------------------------------
        // T6. Mixed pattern: reference computes independently, DUT must match.
        //     32 pixels of deterministic pseudo-random content.
        //     Uses the module-scope cand_arr / hr_arr declared above.
        // ---------------------------------------------------------------------
        test_num = 6;
        do_reset;
        for (i = 0; i < 32; i = i + 1) begin
            cand_arr[i] = (i * 37 + 13) & 8'hFF;
            hr_arr[i]   = (i * 71 + 5)  & 8'hFF;
        end
        for (i = 0; i < 31; i = i + 1)
            drive_pixel(cand_arr[i], hr_arr[i], 1'b0);
        drive_pixel(cand_arr[31], hr_arr[31], 1'b1);
        drive_bubble;
        compute_ref_mse(32);
        expected_mse = ref_mse_result;
        wait_for_mse_valid(10);
        check_mse("mixed_32px");

        // ---------------------------------------------------------------------
        // T7. Consecutive RUs: RU_A (16 px, cand=200, hr=100, diff=100, sq=10000)
        //     immediately followed by RU_B (16 px, cand=50, hr=100, diff=-50, sq=2500).
        //     Verify both latch independently with correct reset between them.
        //     Expected mse_A = 16·10000 = 160_000
        //     Expected mse_B = 16·2500  = 40_000
        // ---------------------------------------------------------------------
        test_num = 7;
        do_reset;
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd200, 8'd100, 1'b0);
        drive_pixel(8'd200, 8'd100, 1'b1);
        expected_mse = 64'd160000;
        wait_for_mse_valid(10);
        check_mse("consecutive_RU_A");

        // Immediately start RU_B without dropping valid_in
        for (i = 0; i < 15; i = i + 1) drive_pixel(8'd50, 8'd100, 1'b0);
        drive_pixel(8'd50, 8'd100, 1'b1);
        drive_bubble;
        expected_mse = 64'd40000;
        wait_for_mse_valid(10);
        check_mse("consecutive_RU_B");

        // ---------------------------------------------------------------------
        // T8. Bubbles mid-RU: 16 pixels, but with 2 bubbles inserted after
        //     the 5th pixel. Bubbles must not corrupt the accumulator.
        //     Same content as T3 (const offset +10) → same expected mse = 1600.
        // ---------------------------------------------------------------------
        test_num = 8;
        do_reset;
        for (i = 0; i < 5; i = i + 1) drive_pixel(8'd100, 8'd90, 1'b0);
        drive_bubble;
        drive_bubble;
        drive_bubble;
        for (i = 5; i < 15; i = i + 1) drive_pixel(8'd100, 8'd90, 1'b0);
        drive_pixel(8'd100, 8'd90, 1'b1);
        drive_bubble;
        expected_mse = 64'd1600;
        wait_for_mse_valid(10);
        check_mse("bubbles_mid_RU");

        // ---------------------------------------------------------------------
        // T9. Swap-timing check: verify mse_valid asserts exactly at the
        //     3rd cycle after the swap sample, and pulses for a single cycle.
        //
        // Sampling on negedge (not posedge) avoids the standard Verilog NBA
        // race — after a posedge, an initial-block read of a signal sees the
        // value BEFORE this cycle's non-blocking updates. Negedge reads see
        // the previous posedge's updates, which is what we want.
        //
        // Timeline after the final drive_pixel(swap=1) + drive_bubble:
        //   drive_pixel[3] set signals at cycle (T-1)-negedge.
        //   DUT sampled swap at cycle T posedge.
        //   drive_bubble set valid_in=0 at cycle T negedge.
        //   Stage 1 latches diff  → end of cycle T
        //   Stage 2 latches sqdiff → end of cycle T+1
        //   Stage 3 latches mse_valid=1 → end of cycle T+2
        //   Stage 3 clears mse_valid → end of cycle T+3
        //   Visible at (T+1)-neg: 0, (T+2)-neg: 1, (T+3)-neg: 0
        // ---------------------------------------------------------------------
        test_num = 9;
        do_reset;
        for (i = 0; i < 3; i = i + 1) drive_pixel(8'd50, 8'd40, 1'b0);
        drive_pixel(8'd50, 8'd40, 1'b1);   // 4th pixel with swap
        drive_bubble;                       // stop driving; pipeline drains

        // Sample 1: (T+1)-negedge — mse_valid still 0 (only stages 1+2 filled)
        @(negedge clk);
        if (mse_valid !== 1'b0) begin
            $display("[T9] FAIL swap_timing_+1 : mse_valid=%0b (expected 0)", mse_valid);
            err_count = err_count + 1;
        end

        // Sample 2: (T+2)-negedge — mse_valid should be 1, mse_out = 400
        //           (4 px × diff=10 × diff=10 = 4·100 = 400)
        @(negedge clk);
        if (mse_valid === 1'b1) begin
            $display("[T9] PASS swap_timing_assert : mse_valid asserted at +2 negedge");
            observed_mse = {31'd0, mse_out};
            expected_mse = 64'd400;
            check_mse("swap_timing_content");
        end else begin
            $display("[T9] FAIL swap_timing_assert : mse_valid=%0b (expected 1)", mse_valid);
            err_count = err_count + 1;
        end

        // Sample 3: (T+3)-negedge — mse_valid should drop back to 0 (single-cycle pulse)
        @(negedge clk);
        if (mse_valid !== 1'b0) begin
            $display("[T9] FAIL swap_timing_pulse : mse_valid still high one cycle later");
            err_count = err_count + 1;
        end else begin
            $display("[T9] PASS swap_timing_pulse : mse_valid pulse was single-cycle");
        end

        // ---------------------------------------------------------------------
        // T10. Swap then immediate idle: valid_in goes low right after swap.
        //      mse_valid must still fire (pipeline drains internally).
        //      Content: 8 px of cand=80/hr=60 → diff=20, sqdiff=400, total=3200
        // ---------------------------------------------------------------------
        test_num = 10;
        do_reset;
        for (i = 0; i < 7; i = i + 1) drive_pixel(8'd80, 8'd60, 1'b0);
        drive_pixel(8'd80, 8'd60, 1'b1);       // swap on 8th pixel
        expected_mse = 64'd3200;
        // Sample mse_valid over the following bubble cycles.
        // Pipeline is 3 deep, so mse_valid should fire on cycle +3 even
        // under continuous valid_in=0.
        begin : t10_check
            integer cyc;
            reg saw_valid;
            saw_valid = 1'b0;
            for (cyc = 0; cyc < 5; cyc = cyc + 1) begin
                @(negedge clk);
                valid_in = 1'b0; swap = 1'b0;
                @(posedge clk);
                if (mse_valid && !saw_valid) begin
                    saw_valid    = 1'b1;
                    observed_mse = {31'd0, mse_out};
                    if (cyc + 1 == 3) begin
                        $display("[T10] PASS swap_then_idle_timing : mse_valid at +%0d",
                                 cyc + 1);
                    end else begin
                        $display("[T10] FAIL swap_then_idle_timing : mse_valid at +%0d (expected +3)",
                                 cyc + 1);
                        err_count = err_count + 1;
                    end
                end
            end
            if (!saw_valid) begin
                $display("[T10] FAIL swap_then_idle_fire : mse_valid never fired");
                err_count = err_count + 1;
            end else begin
                check_mse("swap_then_idle_content");
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

    // ----- Global timeout (belt-and-braces; should never trigger) -----
    initial begin
        #200000;   // 20 µs of sim time — way more than needed
        $display("ERROR: Global timeout — testbench never reached $finish");
        $finish;
    end

endmodule
