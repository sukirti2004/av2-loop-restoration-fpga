`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// tb_selection_regs.v
//
// Self-checking testbench for selection_regs.v.
//
// Uses NUM_RU=8 so we can exhaust the bitmap in a few pulses.
//
// Tests:
//   T1 : reset holds all regs and counter at 0
//   T2 : single NONE selection -> sel_none[0]=1, sel_pc[0]=0, sel_ns[0]=0,
//        num_ru_processed=1
//   T3 : single PC selection continues -> sel_pc[1]=1, others [1]=0
//   T4 : single NS selection continues -> sel_ns[2]=1, others [2]=0
//   T5 : selection_valid=0 with selection=NS -> no update
//   T6 : full sequence of 8 selections (NONE,PC,NS,NONE,PC,NS,NONE,PC)
//        -> sel_none = 0b0001_1001
//           sel_pc   = 0b1010_0010
//           sel_ns   = 0b0100_0100
//           num_ru_processed = 0 after wrap (WR_IDX_W=3 wraps naturally at 8)
//   T7 : clear resets everything
//   T8 : after clear, writing continues from index 0
// -----------------------------------------------------------------------------

module tb_selection_regs;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam integer NUM_RU   = 8;
    localparam integer WR_IDX_W = 3;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    reg               rst;
    reg               clear;
    reg  [1:0]        selection;
    reg               selection_valid;

    wire [NUM_RU-1:0]   sel_none;
    wire [NUM_RU-1:0]   sel_pc;
    wire [NUM_RU-1:0]   sel_ns;
    wire [WR_IDX_W-1:0] num_ru_processed;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    selection_regs #(
        .NUM_RU  (NUM_RU),
        .WR_IDX_W(WR_IDX_W)
    ) dut (
        .clk              (clk),
        .rst              (rst),
        .clear            (clear),
        .selection        (selection),
        .selection_valid  (selection_valid),
        .sel_none         (sel_none),
        .sel_pc           (sel_pc),
        .sel_ns           (sel_ns),
        .num_ru_processed (num_ru_processed)
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
            selection_valid <= 1'b0;
            clear           <= 1'b0;
            @(negedge clk);
        end
    endtask

    task push_selection;
        input [1:0] s;
        begin
            selection       <= s;
            selection_valid <= 1'b1;
            clear           <= 1'b0;
            @(negedge clk);
            selection_valid <= 1'b0;
        end
    endtask

    task pulse_clear;
        begin
            clear           <= 1'b1;
            selection_valid <= 1'b0;
            @(negedge clk);
            clear           <= 1'b0;
        end
    endtask

    task check;
        input [1023:0] tag;
        input          cond;
        begin
            if (cond) begin
                $display("[%s] PASS", tag);
            end else begin
                $display("[%s] FAIL  none=%b pc=%b ns=%b idx=%0d",
                         tag, sel_none, sel_pc, sel_ns, num_ru_processed);
                fails = fails + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        // Initial values
        rst             = 1'b1;
        clear           = 1'b0;
        selection       = 2'd0;
        selection_valid = 1'b0;
        fails           = 0;

        // -- T1 : reset -----------------------------------------------------
        @(negedge clk);
        @(negedge clk);
        check("T1 reset_state", (sel_none === 8'b0) && (sel_pc === 8'b0)
                             && (sel_ns === 8'b0) && (num_ru_processed === 0));
        rst = 1'b0;
        @(negedge clk);

        // -- T2 : NONE at index 0 -------------------------------------------
        push_selection(2'd0);   // NONE
        check("T2 none_at_0", (sel_none === 8'b0000_0001)
                           && (sel_pc   === 8'b0000_0000)
                           && (sel_ns   === 8'b0000_0000)
                           && (num_ru_processed === 1));

        // -- T3 : PC at index 1 ---------------------------------------------
        push_selection(2'd1);   // PC
        check("T3 pc_at_1", (sel_none === 8'b0000_0001)
                         && (sel_pc   === 8'b0000_0010)
                         && (sel_ns   === 8'b0000_0000)
                         && (num_ru_processed === 2));

        // -- T4 : NS at index 2 ---------------------------------------------
        push_selection(2'd2);   // NS
        check("T4 ns_at_2", (sel_none === 8'b0000_0001)
                         && (sel_pc   === 8'b0000_0010)
                         && (sel_ns   === 8'b0000_0100)
                         && (num_ru_processed === 3));

        // -- T5 : selection_valid=0 -> no update ----------------------------
        selection <= 2'd2;   // dangling value
        drive_bubble;
        drive_bubble;
        check("T5 no_update_when_invalid", (sel_none === 8'b0000_0001)
                                        && (sel_pc   === 8'b0000_0010)
                                        && (sel_ns   === 8'b0000_0100)
                                        && (num_ru_processed === 3));

        // -- T6 : fill remaining slots up to index 7 ------------------------
        // Current idx=3. Push NONE at 3, PC at 4, NS at 5, NONE at 6, PC at 7.
        // Expected after all 8 slots filled:
        //   sequence 0..7: NONE, PC, NS, NONE, PC, NS, NONE, PC
        //   sel_none[0,3,6] = 1 -> 0b0100_1001
        //   sel_pc  [1,4,7] = 1 -> 0b1001_0010
        //   sel_ns  [2,5]   = 1 -> 0b0010_0100
        push_selection(2'd0);   // idx 3 NONE
        push_selection(2'd1);   // idx 4 PC
        push_selection(2'd2);   // idx 5 NS
        push_selection(2'd0);   // idx 6 NONE
        push_selection(2'd1);   // idx 7 PC
        // After 8 total writes, WR_IDX_W=3 counter wraps back to 0.
        check("T6 full_bitmap",
              (sel_none === 8'b0100_1001) &&
              (sel_pc   === 8'b1001_0010) &&
              (sel_ns   === 8'b0010_0100) &&
              (num_ru_processed === 0));

        // -- T7 : clear resets everything -----------------------------------
        pulse_clear;
        check("T7 clear_resets_all", (sel_none === 8'b0)
                                  && (sel_pc   === 8'b0)
                                  && (sel_ns   === 8'b0)
                                  && (num_ru_processed === 0));

        // -- T8 : after clear, writes start from idx 0 again ----------------
        push_selection(2'd2);   // NS at 0
        push_selection(2'd0);   // NONE at 1
        check("T8 write_after_clear",
              (sel_none === 8'b0000_0010) &&
              (sel_pc   === 8'b0000_0000) &&
              (sel_ns   === 8'b0000_0001) &&
              (num_ru_processed === 2));

        // -- T9 : clear coincident with selection_valid -> clear wins -------
        // Guarantees priority: even if a stray selection_valid overlaps a
        // clear pulse, the clear wipes state (safer semantic).
        selection       <= 2'd1;
        selection_valid <= 1'b1;
        clear           <= 1'b1;
        @(negedge clk);
        selection_valid <= 1'b0;
        clear           <= 1'b0;
        check("T9 clear_beats_selection", (sel_none === 8'b0)
                                       && (sel_pc   === 8'b0)
                                       && (sel_ns   === 8'b0)
                                       && (num_ru_processed === 0));

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
        #5000;
        $display("TIMEOUT -- simulation ran past expected end");
        $finish;
    end

endmodule
