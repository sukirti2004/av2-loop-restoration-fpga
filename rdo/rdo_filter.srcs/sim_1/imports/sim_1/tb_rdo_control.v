`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_rdo_control.v
//
// Self-checking testbench for rdo_control.v.
//
// Uses RU_SIZE_LOG2 = 2 -> RU_SIZE = 4 -> 16 pixels per RU, so full-RU tests
// finish in a handful of cycles. Behavior is identical at RU_SIZE_LOG2 = 8
// (65536 pixels/RU), just slower to simulate.
//
// Tests:
//   T1 : reset holds swap=0, ru_idx=0
//   T2 : sof alone (no valid_in) clears counters, no swap emitted
//   T3 : one full RU (16 valid pixels) -> swap on pixel 16, ru_idx -> 1
//   T4 : two full RUs back-to-back -> 2 swap pulses, ru_idx -> 2
//   T5 : bubbles (valid_in=0 mid-RU) freeze pixel_ctr, swap still fires on
//        the true 16th valid pixel
//   T6 : sof mid-RU aborts the current RU cleanly, no swap on sof
//   T7 : sof coincident with first valid pixel -> pixel_ctr advances to 1,
//        ru_idx stays 0, no early swap
//   T8 : full RU followed by immediate sof -> next RU counts fresh from 0
// -----------------------------------------------------------------------------

module tb_rdo_control;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam integer RU_SIZE_LOG2 = 2;                        // RU_SIZE = 4
    localparam integer RU_IDX_W     = 4;                        // small for sim
    localparam integer PIXELS_PER_RU = (1 << RU_SIZE_LOG2) *
                                       (1 << RU_SIZE_LOG2);     // 16

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    reg rst;
    reg valid_in;
    reg sof;

    wire               swap;
    wire [RU_IDX_W-1:0] ru_idx_out;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    rdo_control #(
        .RU_SIZE_LOG2(RU_SIZE_LOG2),
        .RU_IDX_W    (RU_IDX_W)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .valid_in   (valid_in),
        .sof        (sof),
        .swap       (swap),
        .ru_idx_out (ru_idx_out)
    );

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    integer swap_count;
    integer fails;
    integer i;

    // swap is now COMBINATIONAL in the DUT (asserted with the last pixel's
    // valid_in, deasserted after the same posedge wraps pixel_ctr). It is
    // only "1" during a narrow window around the pulse posedge -- by the
    // following negedge (when task-based checks run) it has already fallen.
    // swap_snap latches swap on each posedge, giving the checks a stable
    // 1-cycle-wide view (identical timing to the old registered swap).
    reg swap_snap;
    always @(posedge clk) begin
        swap_snap <= swap;
    end

    // Count swap pulses monitored on rising edges.
    always @(posedge clk) begin
        if (swap) swap_count <= swap_count + 1;
    end

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task drive_cycle;
        input v;
        input s;
        begin
            valid_in <= v;
            sof      <= s;
            @(negedge clk);
        end
    endtask

    task drive_bubble;
        begin
            drive_cycle(1'b0, 1'b0);
        end
    endtask

    task check;
        input [1023:0] tag;
        input          cond;
        begin
            if (cond) begin
                $display("[%s] PASS", tag);
            end else begin
                $display("[%s] FAIL  swap=%b ru_idx=%0d swap_count=%0d",
                         tag, swap, ru_idx_out, swap_count);
                fails = fails + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Initial values
        rst        = 1'b1;
        valid_in   = 1'b0;
        sof        = 1'b0;
        swap_count = 0;
        fails      = 0;

        // -- T1 : reset ---------------------------------------------------
        @(negedge clk);
        @(negedge clk);
        check("T1 reset_state", (swap_snap === 1'b0) && (ru_idx_out === 0)
                                                && (swap_count === 0));
        rst = 1'b0;
        @(negedge clk);

        // -- T2 : sof alone clears counters, no swap ----------------------
        drive_cycle(1'b0, 1'b1);   // sof pulse, no valid
        drive_bubble;
        check("T2 sof_no_valid",  (swap_snap === 1'b0) && (ru_idx_out === 0)
                                                  && (swap_count === 0));

        // -- T3 : one full RU (16 valid pixels) ---------------------------
        // Drive 15 valid cycles: pixel_ctr advances 0->15. On the 16th valid
        // cycle, pixel_ctr==LAST_IDX so swap fires and pixel_ctr wraps to 0.
        for (i = 0; i < PIXELS_PER_RU - 1; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        // 16th valid cycle -- swap should fire this cycle
        drive_cycle(1'b1, 1'b0);
        // After drive_cycle, we sampled at negedge; the posedge inside
        // drive_cycle already latched swap=1 and ru_idx=1.
        check("T3a swap_pulsed_at_ru_end", (swap_snap === 1'b1)
                                        && (ru_idx_out === 1));
        drive_bubble;
        check("T3b swap_deasserted", (swap_snap === 1'b0)
                                  && (ru_idx_out === 1));

        // -- T4 : second full RU back-to-back -----------------------------
        for (i = 0; i < PIXELS_PER_RU - 1; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        drive_cycle(1'b1, 1'b0);   // 16th valid of RU 1
        check("T4a second_swap", (swap_snap === 1'b1) && (ru_idx_out === 2));
        drive_bubble;
        check("T4b second_swap_counted", (swap_snap === 1'b0) && (swap_count === 2));

        // -- T5 : bubbles mid-RU freeze counter ---------------------------
        // Drive 8 valid pixels, then 3 bubbles, then 7 more valid.
        // Total 15 valid so far -> no swap yet.
        for (i = 0; i < 8; i = i + 1)  drive_cycle(1'b1, 1'b0);
        for (i = 0; i < 3; i = i + 1)  drive_bubble;
        check("T5a no_swap_during_bubbles", (swap_snap === 1'b0)
                                         && (ru_idx_out === 2));
        for (i = 0; i < 7; i = i + 1)  drive_cycle(1'b1, 1'b0);
        // 15 valid pixels total for RU 2 so far, no swap yet
        check("T5b no_swap_at_pix15", (swap_snap === 1'b0)
                                   && (ru_idx_out === 2));
        drive_cycle(1'b1, 1'b0);   // 16th valid pixel
        check("T5c swap_at_pix16_after_bubbles", (swap_snap === 1'b1)
                                              && (ru_idx_out === 3));
        drive_bubble;
        check("T5d swap_counted_after_bubbles", (swap_snap === 1'b0)
                                             && (swap_count === 3));

        // -- T6 : sof mid-RU aborts, no swap ------------------------------
        for (i = 0; i < 5; i = i + 1)  drive_cycle(1'b1, 1'b0);
        // Now sof without valid_in -> counters clear, no swap
        drive_cycle(1'b0, 1'b1);
        check("T6a sof_midru_no_swap", (swap_snap === 1'b0)
                                    && (ru_idx_out === 0));
        // Drive a full RU to prove counters really did reset
        for (i = 0; i < PIXELS_PER_RU - 1; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        drive_cycle(1'b1, 1'b0);
        check("T6b full_ru_after_sof", (swap_snap === 1'b1) && (ru_idx_out === 1));
        drive_bubble;
        check("T6c full_ru_after_sof_counted", (swap_snap === 1'b0)
                                            && (swap_count === 4));

        // -- T7 : sof coincident with first valid pixel -------------------
        // First reset via sof (previous test left ru_idx=1), then re-run.
        drive_cycle(1'b0, 1'b1);   // sof clears
        drive_bubble;
        // sof + valid_in on the same cycle: pixel_ctr becomes 1, ru_idx=0
        drive_cycle(1'b1, 1'b1);
        check("T7a sof_with_valid_no_early_swap", (swap_snap === 1'b0)
                                               && (ru_idx_out === 0));
        // Drive 15 more valid pixels to complete the RU (16 total)
        for (i = 0; i < PIXELS_PER_RU - 1; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        check("T7b swap_at_16_after_sof_start", (swap_snap === 1'b1)
                                             && (ru_idx_out === 1));
        drive_bubble;
        check("T7c swap_after_sof_counted", (swap_snap === 1'b0)
                                         && (swap_count === 5));

        // -- T8 : full RU then immediate sof, next RU starts fresh --------
        // ru_idx currently 1 (from T7). Complete a second RU.
        for (i = 0; i < PIXELS_PER_RU - 1; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        drive_cycle(1'b1, 1'b0);   // 16th valid -> swap
        check("T8a swap_second_ru", (swap_snap === 1'b1) && (ru_idx_out === 2));
        // Immediately re-sync (sof also gives monitor a cycle to catch swap)
        drive_cycle(1'b0, 1'b1);
        check("T8b sof_after_swap_clears_idx", (swap_snap === 1'b0)
                                            && (ru_idx_out === 0)
                                            && (swap_count === 6));
        for (i = 0; i < PIXELS_PER_RU; i = i + 1) begin
            drive_cycle(1'b1, 1'b0);
        end
        check("T8c fresh_ru_after_sof", (swap_snap === 1'b1)
                                     && (ru_idx_out === 1));
        drive_bubble;
        check("T8d fresh_ru_counted", (swap_snap === 1'b0) && (swap_count === 7));

        // -----------------------------------------------------------------
        $display("");
        $display("==========================================================");
        if (fails == 0)
            $display(" ALL TESTS PASSED ");
        else
            $display(" %0d TEST(S) FAILED", fails);
        $display("==========================================================");
        $finish;
    end

    // Simulation safety: kill run if it runs way past expected end.
    initial begin
        #5000;
        $display("TIMEOUT -- simulation ran past expected end");
        $finish;
    end

endmodule
