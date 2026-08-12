`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.06.2026 14:37:10
// Design Name: 
// Module Name: tb_mac_engine
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

module tb_mac_engine;

reg        clk     = 0;
reg        resetn  = 0;
reg        valid_in = 0;

reg [49*8-1:0]  pixels_flat = 0;
reg [49*16-1:0] taps_flat   = 0;

wire [7:0] pixel_out;
wire       valid_out;

always #5 clk = ~clk;

mac_engine uut (
    .clk(clk), .resetn(resetn), .valid_in(valid_in),
    .pixels_flat(pixels_flat),
    .taps_flat(taps_flat),
    .pixel_out(pixel_out),
    .valid_out(valid_out)
);

// helper to set all pixels to same value
integer i;
task set_all_pixels;
    input [7:0] val;
begin
    for (i = 0; i < 49; i = i + 1)
        pixels_flat[i*8 +: 8] = val;
end
endtask

// helper to set all taps to same value (as Q3.13)
task set_all_taps;
    input signed [15:0] val;
begin
    for (i = 0; i < 49; i = i + 1)
        taps_flat[i*16 +: 16] = val;
end
endtask

task run_and_print;
begin
    valid_in = 1;
    @(posedge clk); #1;   // stage 1 captures
    valid_in = 0;
    @(posedge clk); #1;   // stage 2a
    @(posedge clk); #1;   // stage 2b
    @(posedge clk); #1;   // stage 3a  ← add
    @(posedge clk); #1;   // stage 3b → pixel_out ready  ← add
    $display("pixel_out = %0d", pixel_out);
end
endtask


initial begin
    #20 resetn = 1;
    #10;

    // -------------------------------------------------------
    // Test 1: all pixels = 128, all taps = 1.0 in Q3.13
    // tap = 1.0 → 1 * 8192 = 8192
    // expected = sum(128 * 1.0 for 49 taps) = 255
    // -------------------------------------------------------
    set_all_pixels(8'd128);
    set_all_taps(16'sd8192);
    $display("Test 1 (all px=128, tap=1.0, expect=255):");
    run_and_print;

    // -------------------------------------------------------
    // Test 2: all pixels = 100, all taps = 0.5 in Q3.13
    // tap = 0.5 → 0.5 * 8192 = 4096
    // expected = sum(100 * 0.5 for 49 taps) = 50
    // BUT taps sum to 1.0 total, not each tap = 1.0
    // So with all taps = 4096 (0.5 each):
    // sum = 49 * 100 * 0.5 = 2450 → clips to 255
    // -------------------------------------------------------
    set_all_pixels(8'd100);
    set_all_taps(16'sd4096);
    $display("Test 2 (all px=100, tap=0.5 each, expect=255 clipped):");
    run_and_print;

    // -------------------------------------------------------
    // Test 3: all pixels = 128, taps sum to exactly 1.0
    // each tap = 1/49 in Q3.13 = 8192/49 = 167
    // expected ≈ 128
    // -------------------------------------------------------
    set_all_pixels(8'd128);
    set_all_taps(16'sd167);
    $display("Test 3 (all px=128, taps sum~1.0, expect~128):");
    run_and_print;

    // -------------------------------------------------------
    // Test 4: all pixels = 0 → output must be 0
    // -------------------------------------------------------
    set_all_pixels(8'd0);
    set_all_taps(16'sd8192);
    $display("Test 4 (all px=0, expect=0):");
    run_and_print;

    // -------------------------------------------------------
    // Test 5: pixels = 255, taps = 1.0 → clips to 255
    // -------------------------------------------------------
    set_all_pixels(8'd255);
    set_all_taps(16'sd8192);
    $display("Test 5 (all px=255, tap=1.0, expect=255 clipped):");
    run_and_print;

    #20;
    $display("MAC test complete.");
    $finish;
end

endmodule
