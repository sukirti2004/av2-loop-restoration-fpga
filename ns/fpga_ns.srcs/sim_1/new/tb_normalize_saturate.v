`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 17:02:36
// Design Name: 
// Module Name: tb_normalize_saturate
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

module tb_normalize_saturate;
    reg                clk = 0;
    reg                rst = 1;
    reg                valid_in = 0;
    reg  signed [19:0] sum_in = 0;
    reg         [15:0] norm   = 0;
    wire               valid_out;
    wire        [7:0]  pixel_out;
    integer errors = 0;

    always #5 clk = ~clk;

    normalize_saturate dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in),
        .sum_in(sum_in), .norm(norm),
        .valid_out(valid_out), .pixel_out(pixel_out)
    );

    task apply_and_check(input signed [19:0] s,
                         input        [15:0] n,
                         input        [7:0]  expected);
        begin
            sum_in   = s;
            norm     = n;
            valid_in = 1;
            @(posedge clk); #1;   // edge N   - stage 1 captures
            valid_in = 0;
            sum_in   = 0;
            norm     = 0;
            @(posedge clk); #1;   // edge N+1 - stage 2 captures, output valid
            if (valid_out !== 1'b1) begin
                $display("FAIL: valid_out low"); errors = errors + 1;
            end
            if (pixel_out !== expected) begin
                $display("FAIL: got %0d expected %0d, sum=%0d norm=%0d",
                         pixel_out, expected, $signed(s), n);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // 1. all zero  →  0
        apply_and_check(20'sd0, 16'd0, 8'd0);

        // 2. sum=0, any norm  →  0
        apply_and_check(20'sd0, 16'd12345, 8'd0);

        // 3. Typical mid-pixel: sum = 100 × 128 = 12800, norm = 512 (=1/128 in Q0.16).
        //    product = 12800 × 512 = 6553600
        //    +2^15   = 6586368
        //    >>16    = 100
        apply_and_check(20'sd12800, 16'd512, 8'd100);

        // 4. Boundary: sum = 255 × 128 = 32640, norm = 512  →  ~255 (unclipped)
        //    32640 × 512 = 16711680, +32768 = 16744448, >>16 = 255
        apply_and_check(20'sd32640, 16'd512, 8'd255);

        // 5. Positive saturate: sum = 1000 × 128 = 128000, norm = 512  →  1000, clip to 255
        apply_and_check(20'sd128000, 16'd512, 8'd255);

        // 6. Negative saturate: sum = -16384, norm = 512  →  -128, clip to 0
        apply_and_check(-20'sd16384, 16'd512, 8'd0);

        // 7. Small negative rounds to 0 (not clipped, just 0)
        //    sum=-1, norm=32768.  product=-32768.  +32768=0.  >>16=0.
        apply_and_check(-20'sd1, 16'd32768, 8'd0);

        // 8. Small negative just below zero: sum=-2, norm=32768.
        //    product=-65536. +32768=-32768. >>16 (arith) = -1.  Clip to 0.
        apply_and_check(-20'sd2, 16'd32768, 8'd0);

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
