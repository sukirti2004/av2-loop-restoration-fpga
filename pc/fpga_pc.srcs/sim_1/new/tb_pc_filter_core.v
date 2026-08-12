`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.06.2026 11:19:39
// Design Name: 
// Module Name: tb_pc_filter_core
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

module tb_pc_filter_core;

reg        clk, resetn, valid_in;
reg [49*8-1:0] pixels_flat;
wire [7:0] pixel_out;
wire       valid_out;

// Python trace: ctx=4088, filter_id=54, expected pixel_out=0

pc_filter_core uut (
    .clk(clk), .resetn(resetn), .valid_in(valid_in),
    .pixels_flat(pixels_flat),
    // thresholds Q2.14: [2,4,9,19,44,99,230]
    .t0(16'd2),.t1(16'd4),.t2(16'd9),.t3(16'd19),
    .t4(16'd44),.t5(16'd99),.t6(16'd230),
    .pixel_out(pixel_out), .valid_out(valid_out)
);

always #5 clk = ~clk;

reg [7:0] patch [0:48];
integer i, r, c;

task pack_patch;
    integer p;
    begin
        pixels_flat = 0;
        for (p = 0; p < 49; p = p + 1)
            pixels_flat[p*8 +: 8] = patch[p];
    end
endtask

// ── ADD THIS BLOCK HERE ────────────────────────────────────────────
always @(posedge clk) begin
    if (uut.feat_valid)  $display("t=%0t feat_valid",  $time);
    if (uut.ctx_valid)   $display("t=%0t ctx_valid",   $time);
    if (uut.fid_valid)   $display("t=%0t fid_valid",   $time);
    if (uut.taps_valid)  $display("t=%0t taps_valid",  $time);
    if (valid_out)       $display("t=%0t valid_out",   $time);
end
// ──────────────────────────────────────────────────────────────────


initial begin
    clk = 0; resetn = 0; valid_in = 0; pixels_flat = 0;
    #20; resetn = 1; #10;

    // ── Test 1: horizontal edge - rows 4,5,6=255, rest=0 ─────────
    // Python: feat=[0,0.4,0.4,0.4] ctx=4088 fid=54 pixel_out=0
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd0;
    for (r = 4; r <= 6; r = r + 1)
        for (c = 0; c <= 6; c = c + 1)
            patch[r*7+c] = 8'd255;
    pack_patch;

    @(negedge clk); valid_in = 1;
    @(posedge clk); #1; valid_in = 0;

    // pipeline depth = 12 cycles
    repeat(11) @(posedge clk); #1;
    //wait(valid_out === 1'b1); #1;
    
    if (valid_out === 1'b1 && pixel_out === 8'd0)
        $display("Test 1 PASS: pixel_out=%0d", pixel_out);
    else
        $display("Test 1 FAIL: valid_out=%0b pixel_out=%0d (expected 0)",
                  valid_out, pixel_out);
                    
    // ── Test 2: vertical edge (cols 4,5,6=200 rest=50) ───────────────
    // Python: feats=[0.235,0,0.235,0.235] ctx=4039 fid=15 pixel_out=16
    for (i = 0; i < 49; i = i + 1) patch[i] = 8'd50;
    for (r = 0; r <= 6; r = r + 1) begin
        patch[r*7+4] = 8'd200;
        patch[r*7+5] = 8'd200;
        patch[r*7+6] = 8'd200;
    end
    pack_patch;
    @(negedge clk); valid_in = 1;
    @(posedge clk); #1; valid_in = 0;
    wait(valid_out === 1'b1); #1;
    
    if (valid_out === 1'b1 && pixel_out === 8'd16)
        $display("Test 2 PASS: pixel_out=%0d", pixel_out);
    else
        $display("Test 2 FAIL: valid_out=%0b pixel_out=%0d (expected 15)",
                  valid_out, pixel_out);
    #100;
    $display("Done.");
    $finish;
end

endmodule
