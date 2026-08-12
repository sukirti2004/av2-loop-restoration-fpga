`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_rdo_top.v
//
// Integration testbench for rdo_top.v. Exercises the full pipeline end-to-end:
//   valid_in stream -> rdo_control (swap) -> 3x mse_accumulator (mse_valid)
//                   -> cost_compare (selection) -> selection_regs (sel_x bit)
//
// Uses:
//   RU_SIZE_LOG2 = 2   -> RU_SIZE = 4 -> 16 pixels per RU  (fast sim)
//   NUM_RU       = 8   -> selection bitmap width
//   HR_DELAY     = 0   -> matches Option 8 (all DDR-aligned)
//
// Each test drives one RU worth of pixels with uniform per-pixel candidate
// values (so MSE = 16 * (cand-hr)^2 -- easy to reason about) and checks the
// resulting selection bit lands in the right bit of the right bitmap.
//
// Pipeline latency from LAST pixel of RU (posedge L) to sel_x[N] update:
//   L+1  mse_accumulator stage 2  (s2_swap latches)
//   L+2  mse_accumulator stage 3  (mse_out, mse_valid)
//   L+3  cost_compare stage 1     (cost_x_r, stage1_valid)
//   L+4  cost_compare stage 2     (selection, selection_valid)
//   L+5  selection_regs write     (sel_x[wr_idx] <= 1)
// So after driving 16 valid pixels, wait >=5 idle cycles before checking.
//
// Tests:
//   T1  : reset -> all bitmaps 0, num_ru_processed 0
//   T2  : RU0 where NONE is perfect  -> sel_none[0]=1
//   T3  : RU1 where PC is perfect    -> sel_pc[1]=1
//   T4  : RU2 where NS is perfect    -> sel_ns[2]=1
//   T5  : RU3 where MSEs are tied    -> sel_none[3]=1 (priority)
//   T6  : RU4 with bubbles mid-RU    -> still terminates and selects correctly
//   T7  : clear wipes bitmaps and counter
//   T8  : after clear, lambda + rate cost flip winner (NONE has lowest MSE
//         but huge r_none -> PC wins)
// -----------------------------------------------------------------------------

module tb_rdo_top;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam integer RU_SIZE_LOG2 = 2;    // RU_SIZE = 4
    localparam integer RU_IDX_W     = 4;
    localparam integer NUM_RU       = 8;
    localparam integer WR_IDX_W     = 3;
    localparam integer HR_DELAY     = 0;
    localparam integer PIXELS_PER_RU = 16;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    reg         rst;
    reg         clear;
    reg         valid_in;
    reg         sof;
    reg  [7:0]  hr_px, none_px, pc_px, ns_px;
    reg  [15:0] lambda;
    reg  [15:0] r_none, r_pc, r_ns;

    wire [NUM_RU-1:0]    sel_none, sel_pc, sel_ns;
    wire [WR_IDX_W-1:0]  num_ru_processed;
    wire [RU_IDX_W-1:0]  ru_idx_dispatched;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    rdo_top #(
        .RU_SIZE_LOG2(RU_SIZE_LOG2),
        .RU_IDX_W    (RU_IDX_W),
        .NUM_RU      (NUM_RU),
        .WR_IDX_W    (WR_IDX_W),
        .HR_DELAY    (HR_DELAY)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .clear             (clear),
        .valid_in          (valid_in),
        .sof               (sof),
        .hr_px             (hr_px),
        .none_px           (none_px),
        .pc_px             (pc_px),
        .ns_px             (ns_px),
        .lambda            (lambda),
        .r_none            (r_none),
        .r_pc              (r_pc),
        .r_ns              (r_ns),
        .sel_none          (sel_none),
        .sel_pc            (sel_pc),
        .sel_ns            (sel_ns),
        .num_ru_processed  (num_ru_processed),
        .ru_idx_dispatched (ru_idx_dispatched)
    );

    // -------------------------------------------------------------------------
    // Bookkeeping
    // -------------------------------------------------------------------------
    integer fails;
    integer j;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task idle_cycle;
        begin
            valid_in <= 1'b0;
            sof      <= 1'b0;
            clear    <= 1'b0;
            @(negedge clk);
        end
    endtask

    // Drive one RU: 16 valid pixels, uniform per-pixel candidate values.
    // If first_of_frame=1, pulse sof on the first pixel.
    task drive_ru;
        input [7:0] hr, cand_none, cand_pc, cand_ns;
        input       first_of_frame;
        integer k;
        begin
            for (k = 0; k < PIXELS_PER_RU; k = k + 1) begin
                hr_px    <= hr;
                none_px  <= cand_none;
                pc_px    <= cand_pc;
                ns_px    <= cand_ns;
                valid_in <= 1'b1;
                sof      <= (first_of_frame && (k == 0)) ? 1'b1 : 1'b0;
                clear    <= 1'b0;
                @(negedge clk);
            end
            sof <= 1'b0;
        end
    endtask

    // Drive one RU with 3 mid-RU bubble cycles inserted after pixel 8.
    task drive_ru_with_bubbles;
        input [7:0] hr, cand_none, cand_pc, cand_ns;
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                hr_px<=hr; none_px<=cand_none; pc_px<=cand_pc; ns_px<=cand_ns;
                valid_in <= 1'b1; sof <= 1'b0; clear <= 1'b0;
                @(negedge clk);
            end
            for (k = 0; k < 3; k = k + 1) idle_cycle;
            for (k = 0; k < 8; k = k + 1) begin
                hr_px<=hr; none_px<=cand_none; pc_px<=cand_pc; ns_px<=cand_ns;
                valid_in <= 1'b1; sof <= 1'b0; clear <= 1'b0;
                @(negedge clk);
            end
        end
    endtask

    task wait_pipeline;
        integer k;
        begin
            for (k = 0; k < 6; k = k + 1) idle_cycle;   // 6 = latency 5 + margin
        end
    endtask

    task pulse_clear;
        begin
            valid_in <= 1'b0;
            sof      <= 1'b0;
            clear    <= 1'b1;
            @(negedge clk);
            clear    <= 1'b0;
        end
    endtask

    task check;
        input [1023:0] tag;
        input          cond;
        begin
            if (cond) begin
                $display("[%s] PASS", tag);
            end else begin
                $display("[%s] FAIL  none=%b pc=%b ns=%b nproc=%0d",
                         tag, sel_none, sel_pc, sel_ns, num_ru_processed);
                fails = fails + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        rst      = 1'b1;
        clear    = 1'b0;
        valid_in = 1'b0;
        sof      = 1'b0;
        hr_px    = 8'd0;
        none_px  = 8'd0;
        pc_px    = 8'd0;
        ns_px    = 8'd0;
        lambda   = 16'd0;
        r_none   = 16'd0;
        r_pc     = 16'd0;
        r_ns     = 16'd0;
        fails    = 0;

        // -- T1 : reset -----------------------------------------------------
        @(negedge clk);
        @(negedge clk);
        check("T1 reset_state", (sel_none === 8'd0) && (sel_pc === 8'd0)
                             && (sel_ns === 8'd0) && (num_ru_processed === 0));
        rst = 1'b0;
        @(negedge clk);

        // Lambda = 0 for T2..T7 so MSE is the only cost driver.
        lambda <= 16'd0;
        r_none <= 16'd0;
        r_pc   <= 16'd0;
        r_ns   <= 16'd0;
        @(negedge clk);

        // -- T2 : RU0, NONE perfect ----------------------------------------
        // hr=100, none=100 (diff=0), pc=110 (diff=10, sqd=100), ns=120 (diff=20, sqd=400)
        //   MSE_none=0, MSE_pc=1600, MSE_ns=6400 -> NONE wins
        drive_ru(8'd100, 8'd100, 8'd110, 8'd120, 1'b1);
        wait_pipeline;
        check("T2 ru0_none_wins",
              (sel_none === 8'b0000_0001) &&
              (sel_pc   === 8'b0000_0000) &&
              (sel_ns   === 8'b0000_0000) &&
              (num_ru_processed === 1));

        // -- T3 : RU1, PC perfect ------------------------------------------
        // hr=100, none=110, pc=100, ns=120  -> PC wins
        drive_ru(8'd100, 8'd110, 8'd100, 8'd120, 1'b0);
        wait_pipeline;
        check("T3 ru1_pc_wins",
              (sel_none === 8'b0000_0001) &&
              (sel_pc   === 8'b0000_0010) &&
              (sel_ns   === 8'b0000_0000) &&
              (num_ru_processed === 2));

        // -- T4 : RU2, NS perfect ------------------------------------------
        // hr=100, none=110, pc=120, ns=100  -> NS wins
        drive_ru(8'd100, 8'd110, 8'd120, 8'd100, 1'b0);
        wait_pipeline;
        check("T4 ru2_ns_wins",
              (sel_none === 8'b0000_0001) &&
              (sel_pc   === 8'b0000_0010) &&
              (sel_ns   === 8'b0000_0100) &&
              (num_ru_processed === 3));

        // -- T5 : RU3, tie (all zero MSE) -> NONE by priority --------------
        drive_ru(8'd100, 8'd100, 8'd100, 8'd100, 1'b0);
        wait_pipeline;
        check("T5 ru3_tie_none",
              (sel_none === 8'b0000_1001) &&
              (sel_pc   === 8'b0000_0010) &&
              (sel_ns   === 8'b0000_0100) &&
              (num_ru_processed === 4));

        // -- T6 : RU4 with mid-RU bubbles, NONE perfect --------------------
        // Bubbles should not affect MSE. hr=100, none=100, pc=105, ns=110
        //   MSE_none=0, MSE_pc=400, MSE_ns=1600 -> NONE wins
        drive_ru_with_bubbles(8'd100, 8'd100, 8'd105, 8'd110);
        wait_pipeline;
        check("T6 ru4_bubbles_none",
              (sel_none === 8'b0001_1001) &&
              (sel_pc   === 8'b0000_0010) &&
              (sel_ns   === 8'b0000_0100) &&
              (num_ru_processed === 5));

        // -- T7 : clear wipes bitmaps + counter ----------------------------
        pulse_clear;
        @(negedge clk);
        check("T7 clear_resets_all",
              (sel_none === 8'd0) && (sel_pc === 8'd0) &&
              (sel_ns === 8'd0)   && (num_ru_processed === 0));

        // -- T8 : lambda flips winner --------------------------------------
        // NONE has lowest MSE (0), PC and NS have MSE 1600 and 6400.
        // With lambda=1, r_none=10000, r_pc=1, r_ns=1:
        //   cost_none = 0    + 1 * 10000 = 10000
        //   cost_pc   = 1600 + 1 *     1 =  1601
        //   cost_ns   = 6400 + 1 *     1 =  6401
        // -> PC wins.
        lambda <= 16'd1;
        r_none <= 16'd10000;
        r_pc   <= 16'd1;
        r_ns   <= 16'd1;
        @(negedge clk);
        // Note: no sof here -- clear already reset ru_idx via selection_regs,
        // but rdo_control's ru_idx_out and pixel_ctr are unchanged. Use sof
        // to re-sync rdo_control for a fresh frame.
        drive_ru(8'd100, 8'd100, 8'd110, 8'd120, 1'b1);
        wait_pipeline;
        check("T8 lambda_flips_to_pc",
              (sel_none === 8'b0000_0000) &&
              (sel_pc   === 8'b0000_0001) &&
              (sel_ns   === 8'b0000_0000) &&
              (num_ru_processed === 1));

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

    initial begin
        #20000;
        $display("TIMEOUT -- simulation ran past expected end");
        $finish;
    end

endmodule
