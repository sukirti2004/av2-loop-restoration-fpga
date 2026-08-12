`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 23.06.2026 17:14:41
// Design Name: 
// Module Name: tb_quantizer_ctx
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

module tb_quantizer_ctx;

// clock and reset
reg clk    = 0;
reg resetn = 0;

always #5 clk = ~clk;  // 100MHz clock

// inputs
reg signed [15:0] feat0, feat1, feat2, feat3;
reg [15:0] thresh_f0_0, thresh_f0_1, thresh_f0_2, thresh_f0_3,
           thresh_f0_4, thresh_f0_5, thresh_f0_6;
reg [15:0] thresh_f1_0, thresh_f1_1, thresh_f1_2, thresh_f1_3,
           thresh_f1_4, thresh_f1_5, thresh_f1_6;
reg [15:0] thresh_f2_0, thresh_f2_1, thresh_f2_2, thresh_f2_3,
           thresh_f2_4, thresh_f2_5, thresh_f2_6;
reg [15:0] thresh_f3_0, thresh_f3_1, thresh_f3_2, thresh_f3_3,
           thresh_f3_4, thresh_f3_5, thresh_f3_6;
reg valid_in = 0;

// outputs
wire [11:0] ctx_out;
wire        valid_out;

// instantiate
quantizer_ctx uut (
    .clk(clk), .resetn(resetn), .valid_in(valid_in),
    .feat0(feat0), .feat1(feat1), .feat2(feat2), .feat3(feat3),
    .thresh_f0_0(thresh_f0_0), .thresh_f0_1(thresh_f0_1),
    .thresh_f0_2(thresh_f0_2), .thresh_f0_3(thresh_f0_3),
    .thresh_f0_4(thresh_f0_4), .thresh_f0_5(thresh_f0_5),
    .thresh_f0_6(thresh_f0_6),
    .thresh_f1_0(thresh_f1_0), .thresh_f1_1(thresh_f1_1),
    .thresh_f1_2(thresh_f1_2), .thresh_f1_3(thresh_f1_3),
    .thresh_f1_4(thresh_f1_4), .thresh_f1_5(thresh_f1_5),
    .thresh_f1_6(thresh_f1_6),
    .thresh_f2_0(thresh_f2_0), .thresh_f2_1(thresh_f2_1),
    .thresh_f2_2(thresh_f2_2), .thresh_f2_3(thresh_f2_3),
    .thresh_f2_4(thresh_f2_4), .thresh_f2_5(thresh_f2_5),
    .thresh_f2_6(thresh_f2_6),
    .thresh_f3_0(thresh_f3_0), .thresh_f3_1(thresh_f3_1),
    .thresh_f3_2(thresh_f3_2), .thresh_f3_3(thresh_f3_3),
    .thresh_f3_4(thresh_f3_4), .thresh_f3_5(thresh_f3_5),
    .thresh_f3_6(thresh_f3_6),
    .ctx_out(ctx_out), .valid_out(valid_out)
);

// ----------------------------------------------------------------
// Thresholds from Day 3 measurements, QP group 1, Q2.14 scaled
// Original: [9.4e-05, 2.6e-04, 5.4e-04, 1.1e-03, 2.6e-03, 6.0e-03, 1.4e-02]
// Scaled by 2^14 = 16384 and rounded
// ----------------------------------------------------------------
task load_thresholds;
begin
    // feature 0 thresholds (Q2.14 = multiply by 16384)
    thresh_f0_0 = 16'd2;    // 9.4e-05 * 16384 = 1.54  → 2
    thresh_f0_1 = 16'd4;    // 2.6e-04 * 16384 = 4.26  → 4
    thresh_f0_2 = 16'd9;    // 5.4e-04 * 16384 = 8.85  → 9
    thresh_f0_3 = 16'd19;   // 1.1e-03 * 16384 = 18.0  → 19
    thresh_f0_4 = 16'd44;   // 2.6e-03 * 16384 = 42.6  → 44
    thresh_f0_5 = 16'd99;   // 6.0e-03 * 16384 = 98.3  → 99
    thresh_f0_6 = 16'd230;  // 1.4e-02 * 16384 = 229.4 → 230

    // feature 1 thresholds (same values for this test - replace with real ones)
    thresh_f1_0 = 16'd2;  thresh_f1_1 = 16'd4;  thresh_f1_2 = 16'd9;
    thresh_f1_3 = 16'd19; thresh_f1_4 = 16'd44; thresh_f1_5 = 16'd99;
    thresh_f1_6 = 16'd230;

    // feature 2 thresholds
    thresh_f2_0 = 16'd2;  thresh_f2_1 = 16'd4;  thresh_f2_2 = 16'd9;
    thresh_f2_3 = 16'd19; thresh_f2_4 = 16'd44; thresh_f2_5 = 16'd99;
    thresh_f2_6 = 16'd230;

    // feature 3 thresholds
    thresh_f3_0 = 16'd2;  thresh_f3_1 = 16'd4;  thresh_f3_2 = 16'd9;
    thresh_f3_3 = 16'd19; thresh_f3_4 = 16'd44; thresh_f3_5 = 16'd99;
    thresh_f3_6 = 16'd230;
end
endtask

// ----------------------------------------------------------------
// Test cases - values in Q2.14 (multiply float by 16384)
// Expected ctx = {lv3, lv2, lv1, lv0} packed 12-bit
// ----------------------------------------------------------------
task apply_and_check;
    input signed [15:0] f0, f1, f2, f3;
    input [11:0] expected_ctx;
    input [63:0] test_num;
begin
    feat0    = f0;
    feat1    = f1;
    feat2    = f2;
    feat3    = f3;
    valid_in = 1;
    @(posedge clk); #1;
    valid_in = 0;
    @(posedge clk); #1;

    if (ctx_out === expected_ctx)
        $display("PASS test %0d: ctx_out=%b", test_num, ctx_out);
    else
        $display("FAIL test %0d: got=%b expected=%b", test_num, ctx_out, expected_ctx);
end
endtask

initial begin
    // load thresholds
    load_thresholds;

    // release reset after 20ns
    #20 resetn = 1;
    #10;

    // ----------------------------------------------------------------
    // Test 1: all features = 0
    // abs = 0, exceeds 0 thresholds → all levels = 0
    // expected ctx = {000, 000, 000, 000} = 12'b0
    // ----------------------------------------------------------------
    apply_and_check(16'sd0, 16'sd0, 16'sd0, 16'sd0,
                    12'b000_000_000_000, 1);

    // ----------------------------------------------------------------
    // Test 2: feat0 = 0.001 in Q2.14 = 16 (exceeds thresh 0,1,2 = levels 3)
    //         rest = 0
    // lv0=3, lv1=0, lv2=0, lv3=0
    // ctx = {000, 000, 000, 011} = 12'b000_000_000_011
    // ----------------------------------------------------------------
    apply_and_check(16'sd16, 16'sd0, 16'sd0, 16'sd0,
                    12'b000_000_000_011, 2);

    // ----------------------------------------------------------------
    // Test 3: all features = large value (exceeds all 7 thresholds → level 7)
    // feat = 0.1 in Q2.14 = 1638
    // lv0=lv1=lv2=lv3=7
    // ctx = {111, 111, 111, 111} = 12'hFFF
    // ----------------------------------------------------------------
    apply_and_check(16'sd1638, 16'sd1638, 16'sd1638, 16'sd1638,
                    12'hFFF, 3);

    // ----------------------------------------------------------------
    // Test 4: negative feature - abs should handle it same as positive
    // feat0 = -16 → abs = 16 → same as test 2
    // ----------------------------------------------------------------
    apply_and_check(-16'sd16, 16'sd0, 16'sd0, 16'sd0,
                    12'b000_000_000_011, 4);

    #20;
    $display("Testbench complete.");
    $finish;
end

endmodule