`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 22:51:54
// Design Name: 
// Module Name: tb_control
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

module tb_control;
    reg  clk = 0;
    reg  rst = 1;
    reg  valid_in = 0;
    reg  sof = 0;
    wire swap;
    integer errors = 0;
    integer i;
    integer expected_swap;

    always #5 clk = ~clk;

    // Small frame for testing: 4x4 pixels, 2x2 RUs (four RUs total).
    control #(.FRAME_W(4), .RU_SHIFT(1)) dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .sof(sof),
        .swap(swap)
    );

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // Feed 16 pixels of a 4x4 frame in raster order; SOF on the first only.
        //
        //   RU layout (each cell shows the RU index the pixel belongs to):
        //      (0,0) (0,0) | (0,1) (0,1)
        //      (0,0) (0,0) | (0,1) (0,1)
        //      -----+-----+-----+-----
        //      (1,0) (1,0) | (1,1) (1,1)
        //      (1,0) (1,0) | (1,1) (1,1)
        //
        //   Raster sequence i -> RU:
        //      i=0 (0,0):(0,0)  new         -> swap
        //      i=1 (0,1):(0,0)  same        -> no swap
        //      i=2 (0,2):(0,1)  new         -> swap
        //      i=3 (0,3):(0,1)  same        -> no swap
        //      i=4 (1,0):(0,0)  new         -> swap
        //      i=5 (1,1):(0,0)  same        -> no swap
        //      i=6 (1,2):(0,1)  new         -> swap
        //      i=7 (1,3):(0,1)  same        -> no swap
        //      i=8 (2,0):(1,0)  new         -> swap
        //      i=9 (2,1):(1,0)  same        -> no swap
        //      i=10(2,2):(1,1)  new         -> swap
        //      i=11(2,3):(1,1)  same        -> no swap
        //      i=12(3,0):(1,0)  new         -> swap
        //      i=13(3,1):(1,0)  same        -> no swap
        //      i=14(3,2):(1,1)  new         -> swap
        //      i=15(3,3):(1,1)  same        -> no swap
        //
        // Swap fires whenever i is even.

        valid_in = 1;
        sof = 1;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk); #1;
            sof = 0;
            expected_swap = (i[0] == 1'b0) ? 1 : 0;
            if (swap !== expected_swap[0]) begin
                $display("FAIL i=%0d: swap=%0d expected %0d",
                         i, swap, expected_swap);
                errors = errors + 1;
            end
        end
        valid_in = 0;

        // Swap should drop when valid_in drops
        @(posedge clk); #1;
        if (swap !== 1'b0) begin
            $display("FAIL: swap high after valid_in dropped");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule