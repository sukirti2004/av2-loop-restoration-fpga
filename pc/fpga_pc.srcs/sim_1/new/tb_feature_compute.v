`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.06.2026 09:22:57
// Design Name: 
// Module Name: tb_feature_compute
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

module tb_feature_compute;

reg         clk, resetn, valid_in;
reg [49*8-1:0] pixels_flat;

wire signed [15:0] feat0, feat1, feat2, feat3;
wire               valid_out;

feature_compute uut (
    .clk(clk), .resetn(resetn), .valid_in(valid_in),
    .pixels_flat(pixels_flat),
    .feat0(feat0), .feat1(feat1),
    .feat2(feat2), .feat3(feat3),
    .valid_out(valid_out)
);

always #5 clk = ~clk;

// helper: 7x7 patch storage
reg [7:0] patch [0:48];
integer i, r, c;

// pack patch[] into pixels_flat
task pack_patch;
    integer p;
    begin
        pixels_flat = 0;
        for (p = 0; p < 49; p = p + 1)
            pixels_flat[p*8 +: 8] = patch[p];
    end
endtask

// apply one pixel and check output one cycle later
task apply_and_check;
    input integer       test_num;
    input signed [15:0] exp0, exp1, exp2, exp3;
    begin
        @(negedge clk); valid_in = 1;
        @(posedge clk); #1; valid_in = 0;
        repeat(3) @(posedge clk); #1;  // wait 2 more cycles (3 total)
        if (feat0===exp0 && feat1===exp1 && feat2===exp2 && feat3===exp3)
            $display("Test %0d PASS: (%0d, %0d, %0d, %0d)",
                      test_num, feat0, feat1, feat2, feat3);
        else begin
            $display("Test %0d FAIL:", test_num);
            $display("  Expected: (%0d, %0d, %0d, %0d)", exp0, exp1, exp2, exp3);
            $display("  Got:      (%0d, %0d, %0d, %0d)", feat0, feat1, feat2, feat3);
        end
    end
endtask
initial begin
    clk = 0; resetn = 0; valid_in = 0; pixels_flat = 0;
    #20; resetn = 1; #10;

    // ── Test 1: all zeros ──────────────────────────────────────────
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd0;
    pack_patch;
    apply_and_check(1, 16'd0, 16'd0, 16'd0, 16'd0);

    // ── Test 2: horizontal edge - rows 4,5,6 = 255, rest = 0 ──────
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd0;
    for (r = 4; r <= 6; r = r + 1)
        for (c = 0; c <= 6; c = c + 1)
            patch[r*7+c] = 8'd255;
    pack_patch;
    apply_and_check(2, 16'd0, 16'd6552, 16'd6552, 16'd6552);

    // ── Test 3: vertical edge - cols 4,5,6 = 255, rest = 0 ────────
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd0;
    for (r = 0; r <= 6; r = r + 1)
        for (c = 4; c <= 6; c = c + 1)
            patch[r*7+c] = 8'd255;
    pack_patch;
    apply_and_check(3, 16'd6552, 16'd0, 16'd6552, 16'd6552);

    // ── Test 4: uniform 128 ────────────────────────────────────────
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd128;
    pack_patch;
    apply_and_check(4, 16'd0, 16'd0, 16'd0, 16'd0);

    #50;
    $display("All tests done.");
    $finish;
end

endmodule
