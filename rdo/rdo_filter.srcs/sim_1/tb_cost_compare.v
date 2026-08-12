`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_cost_compare.v
//
// Self-checking testbench for cost_compare.v.
//
// Verifies:
//   T1 : reset holds selection=0, selection_valid=0
//   T2 : NONE has strict min cost -> selection=0
//   T3 : PC has strict min cost -> selection=1
//   T4 : NS has strict min cost -> selection=2
//   T5 : all three costs equal -> NONE wins (tie-break priority NONE > PC > NS)
//   T6 : PC == NS, both < NONE -> PC wins (tie-break PC > NS)
//   T7 : NONE == PC, both < NS -> NONE wins
//   T8 : lambda*r shifts the winner (NONE has lowest MSE but huge r_none)
//   T9 : back-to-back mse_valid pulses produce back-to-back selections
//        (validates 2-stage pipeline correctly serializes)
//  T10 : latency check -- selection_valid arrives EXACTLY 2 cycles after mse_valid
// -----------------------------------------------------------------------------

module tb_cost_compare;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    reg         rst;
    reg  [32:0] mse_none, mse_pc, mse_ns;
    reg         mse_valid;
    reg  [15:0] lambda;
    reg  [15:0] r_none, r_pc, r_ns;

    wire [1:0]  selection;
    wire        selection_valid;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    cost_compare dut (
        .clk             (clk),
        .rst             (rst),
        .mse_none        (mse_none),
        .mse_pc          (mse_pc),
        .mse_ns          (mse_ns),
        .mse_valid       (mse_valid),
        .lambda          (lambda),
        .r_none          (r_none),
        .r_pc            (r_pc),
        .r_ns            (r_ns),
        .selection       (selection),
        .selection_valid (selection_valid)
    );

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    integer fails;
    integer i;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task drive_bubble;
        begin
            mse_valid <= 1'b0;
            @(negedge clk);
        end
    endtask

    // Present one mse triple + pulse mse_valid for 1 cycle.
    task drive_mse;
        input [32:0] a;   // NONE
        input [32:0] b;   // PC
        input [32:0] c;   // NS
        begin
            mse_none  <= a;
            mse_pc    <= b;
            mse_ns    <= c;
            mse_valid <= 1'b1;
            @(negedge clk);
            mse_valid <= 1'b0;
        end
    endtask

    // Wait n negedges (n clock cycles).
    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    task check;
        input [1023:0] tag;
        input          cond;
        begin
            if (cond) begin
                $display("[%s] PASS", tag);
            end else begin
                $display("[%s] FAIL  selection=%0d selection_valid=%b",
                         tag, selection, selection_valid);
                fails = fails + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Initial values
        rst       = 1'b1;
        mse_none  = 33'd0;
        mse_pc    = 33'd0;
        mse_ns    = 33'd0;
        mse_valid = 1'b0;
        lambda    = 16'd0;
        r_none    = 16'd0;
        r_pc      = 16'd0;
        r_ns      = 16'd0;
        fails     = 0;

        // -- T1 : reset -------------------------------------------------------
        @(negedge clk);
        @(negedge clk);
        check("T1 reset_state", (selection === 2'd0)
                             && (selection_valid === 1'b0));
        rst = 1'b0;
        @(negedge clk);

        // Common lambda for T2..T7 : keep small so MSE dominates.
        lambda <= 16'd1;
        r_none <= 16'd0;
        r_pc   <= 16'd0;
        r_ns   <= 16'd0;
        @(negedge clk);

        // -- T2 : NONE wins ---------------------------------------------------
        // Timing: drive_mse spans one clock; DUT samples mse_valid=1 during
        // that cycle. selection_valid rises the FOLLOWING posedge, i.e., one
        // more @(negedge clk) after drive_mse returns.
        drive_mse(33'd100, 33'd200, 33'd300);   // NONE lowest
        @(negedge clk);
        check("T2 none_wins", (selection === 2'd0)
                           && (selection_valid === 1'b1));
        drive_bubble;
        check("T2b sv_deasserted", (selection_valid === 1'b0));

        // -- T3 : PC wins -----------------------------------------------------
        drive_mse(33'd500, 33'd100, 33'd400);
        wait_cycles(1);
        check("T3 pc_wins",  (selection === 2'd1)
                          && (selection_valid === 1'b1));
        drive_bubble;

        // -- T4 : NS wins -----------------------------------------------------
        drive_mse(33'd500, 33'd400, 33'd100);
        wait_cycles(1);
        check("T4 ns_wins",  (selection === 2'd2)
                          && (selection_valid === 1'b1));
        drive_bubble;

        // -- T5 : 3-way tie -> NONE wins --------------------------------------
        drive_mse(33'd200, 33'd200, 33'd200);
        wait_cycles(1);
        check("T5 tie_all_none",  (selection === 2'd0)
                               && (selection_valid === 1'b1));
        drive_bubble;

        // -- T6 : PC == NS < NONE -> PC wins ----------------------------------
        drive_mse(33'd500, 33'd100, 33'd100);
        wait_cycles(1);
        check("T6 tie_pcns_pc",  (selection === 2'd1)
                              && (selection_valid === 1'b1));
        drive_bubble;

        // -- T7 : NONE == PC < NS -> NONE wins --------------------------------
        drive_mse(33'd100, 33'd100, 33'd500);
        wait_cycles(1);
        check("T7 tie_nonepc_none",  (selection === 2'd0)
                                  && (selection_valid === 1'b1));
        drive_bubble;

        // -- T8 : lambda*r flips the winner -----------------------------------
        // NONE has lowest MSE (100), PC 300, NS 400. Without lambda, NONE wins.
        // Set lambda=10, r_none=100, r_pc=1, r_ns=1.
        //   cost_none = 100 + 10*100 = 1100
        //   cost_pc   = 300 + 10*1   = 310
        //   cost_ns   = 400 + 10*1   = 410
        // -> PC wins.
        lambda <= 16'd10;
        r_none <= 16'd100;
        r_pc   <= 16'd1;
        r_ns   <= 16'd1;
        @(negedge clk);
        drive_mse(33'd100, 33'd300, 33'd400);
        wait_cycles(1);
        check("T8 lambda_flips_to_pc",  (selection === 2'd1)
                                     && (selection_valid === 1'b1));
        drive_bubble;

        // Reset lambda for subsequent tests
        lambda <= 16'd1;
        r_none <= 16'd0;
        r_pc   <= 16'd0;
        r_ns   <= 16'd0;
        @(negedge clk);

        // -- T9 : back-to-back mse_valid pulses -------------------------------
        // Pulse 3 consecutive mse triples; expect 3 consecutive selection
        // pulses starting 2 cycles after the first mse_valid.
        // Triple 1: NONE wins (100/200/300)
        // Triple 2: PC wins   (500/100/400)
        // Triple 3: NS wins   (500/400/100)
        //
        // Timing (negedge relative to first mse_valid pulse):
        //   t=0: pulse #1 arrives
        //   t=1: pulse #2 arrives (also stage1 for #1)
        //   t=2: pulse #3 arrives (stage1 for #2, selection_valid for #1)
        //   t=3: selection_valid for #2
        //   t=4: selection_valid for #3
        drive_mse(33'd100, 33'd200, 33'd300);   // t=0, sets mse_valid high, waits 1 negedge
        drive_mse(33'd500, 33'd100, 33'd400);   // t=1
        drive_mse(33'd500, 33'd400, 33'd100);   // t=2 -- but this cycle sv for #1 pulses
        // After third drive_mse returns, we are at t=3 (negedge) with mse_valid=0.
        // At this instant, selection_valid should reflect the previous cycle's
        // stage1 result (which was pulse #2 -> PC wins).
        check("T9a back2back_pc_pulse", (selection === 2'd1)
                                     && (selection_valid === 1'b1));
        @(negedge clk);   // t=4
        check("T9b back2back_ns_pulse", (selection === 2'd2)
                                     && (selection_valid === 1'b1));
        @(negedge clk);   // t=5
        check("T9c sv_finally_low", (selection_valid === 1'b0));

        // Also verify pulse #1 (NONE) had appeared at t=2. We can't rewind
        // in a linear TB, but we can rerun the sequence and check earlier.
        drive_bubble;
        drive_bubble;

        // -- T10 : precise latency check --------------------------------------
        // Right after drive_mse returns, sv should still be low (stage 1 has
        // latched cost, but stage 2 hasn't fired yet). Exactly one more
        // @(negedge clk) later, sv should be high. The cycle after, sv falls.
        drive_mse(33'd50, 33'd60, 33'd70);   // NONE wins
        check("T10a sv_low_at_drive_return", (selection_valid === 1'b0));
        @(negedge clk);
        check("T10b sv_high_after_1cyc", (selection === 2'd0)
                                      && (selection_valid === 1'b1));
        @(negedge clk);
        check("T10c sv_low_after_2cyc", (selection_valid === 1'b0));

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

    // Simulation safety
    initial begin
        #5000;
        $display("TIMEOUT -- simulation ran past expected end");
        $finish;
    end

endmodule
