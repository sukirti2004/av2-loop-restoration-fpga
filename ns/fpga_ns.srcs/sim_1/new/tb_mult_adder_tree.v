`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 16:38:26
// Design Name: 
// Module Name: tb_mult_adder_tree
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

module tb_mult_adder_tree;
    reg          clk = 0;
    reg          rst = 1;
    reg          valid_in = 0;
    reg  [107:0] pair_sums = 0;
    reg   [83:0] taps      = 0;
    wire         valid_out;
    wire signed [19:0] sum_out;
    integer errors = 0;

    always #5 clk = ~clk;   // 100 MHz sim clock

    mult_adder_tree dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in),
        .pair_sums(pair_sums),
        .taps(taps),
        .valid_out(valid_out),
        .sum_out(sum_out)
    );

    // Set pair-sum + tap for one lane. `t` is an ordinary int; low 7 bits
    // land in the tap slot as 2's complement, so -64..+63 all work.
    task set_lane(input integer idx, input [8:0] ps, input integer t);
        begin
            pair_sums[9*idx +: 9] = ps;
            taps     [7*idx +: 7] = t[6:0];
        end
    endtask

    // Apply the currently-set inputs for one cycle, wait 3 cycles for the
    // pipeline, then check the output.
    task apply_and_check(input signed [19:0] expected);
        begin
            valid_in  = 1;
            @(posedge clk); #1;      // edge N   - stage 1 captures
            valid_in  = 0;
            pair_sums = 0;
            taps      = 0;
            @(posedge clk); #1;      // edge N+1 - stage 2 captures
            @(posedge clk); #1;      // edge N+2 - stage 3 captures, output valid
            if (valid_out !== 1'b1) begin
                $display("FAIL: valid_out low"); errors = errors + 1;
            end
            if (sum_out !== expected) begin
                $display("FAIL: got %0d expected %0d",
                         $signed(sum_out), $signed(expected));
                errors = errors + 1;
            end
        end
    endtask

    integer j;
    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // 1. all zeros
        pair_sums = 0; taps = 0;
        apply_and_check(20'sd0);

        // 2. one lane positive: 100 × 10 = 1000
        pair_sums = 0; taps = 0;
        set_lane(0, 9'd100, 10);
        apply_and_check(20'sd1000);

        // 3. one lane negative: 100 × -5 = -500
        pair_sums = 0; taps = 0;
        set_lane(0, 9'd100, -5);
        apply_and_check(-20'sd500);

        // 4. all 12 lanes uniform: 12 × (100 × 1) = 1200
        pair_sums = 0; taps = 0;
        for (j = 0; j < 12; j = j + 1) set_lane(j, 9'd100, 1);
        apply_and_check(20'sd1200);

        // 5. cancellation: +6000 + -6000 = 0
        pair_sums = 0; taps = 0;
        set_lane(0, 9'd100,  60);
        set_lane(1, 9'd100, -60);
        apply_and_check(20'sd0);

        // 6. worst-case positive: 12 × (510 × 63) = 385,560
        pair_sums = 0; taps = 0;
        for (j = 0; j < 12; j = j + 1) set_lane(j, 9'd510, 63);
        apply_and_check(20'sd385560);

        // 7. worst-case negative: 12 × (510 × -64) = -391,680
        pair_sums = 0; taps = 0;
        for (j = 0; j < 12; j = j + 1) set_lane(j, 9'd510, -64);
        apply_and_check(-20'sd391680);

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
