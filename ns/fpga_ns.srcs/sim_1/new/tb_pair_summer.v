`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 16:26:12
// Design Name: 
// Module Name: tb_pair_summer
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

module tb_pair_summer;
    reg  [391:0] window;
    wire [107:0] pair_sums;
    integer errors;

    pair_summer dut (.window(window), .pair_sums(pair_sums));

    // Helper: pack 12 sums into the expected 108-bit bus.
    // s0 in bits [8:0], s1 in [17:9], ..., s11 in [107:99].
    function [107:0] pack_sums(
        input [8:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11
    );
        pack_sums = {s11, s10, s9, s8, s7, s6, s5, s4, s3, s2, s1, s0};
    endfunction

    // Helper: build a window where all 49 pixels have the same value.
    function [391:0] fill_window(input [7:0] v);
        integer i;
        begin
            fill_window = 0;
            for (i = 0; i < 49; i = i + 1)
                fill_window[8*i +: 8] = v;
        end
    endfunction

    initial begin
        errors = 0;

        // Test 1: all zeros
        window = fill_window(8'd0);
        #1;
        if (pair_sums !== pack_sums(9'd0,9'd0,9'd0,9'd0,9'd0,9'd0,
                                    9'd0,9'd0,9'd0,9'd0,9'd0,9'd0)) begin
            $display("FAIL test 1"); errors = errors + 1;
        end

        // Test 2: all 255 → each pair = 510, center = 255
        window = fill_window(8'd255);
        #1;
        if (pair_sums !== pack_sums(9'd510,9'd510,9'd510,9'd510,9'd510,9'd510,
                                    9'd510,9'd510,9'd510,9'd510,9'd510,9'd255))
        begin
            $display("FAIL test 2"); errors = errors + 1;
        end

        // Test 3: only the center pixel is 100, everything else 0
        window = 392'd0;
        window[8*24 +: 8] = 8'd100;
        #1;
        if (pair_sums !== pack_sums(9'd0,9'd0,9'd0,9'd0,9'd0,9'd0,
                                    9'd0,9'd0,9'd0,9'd0,9'd0,9'd100)) begin
            $display("FAIL test 3"); errors = errors + 1;
        end

        // Test 4: distinct-pixel pair check.
        // Set px[3]=10, px[45]=20 → pair 0 should be 30.
        // Set px[9]=100, px[39]=200 → pair 1 should be 300.
        // All other diamond cells 0.
        window = 392'd0;
        window[8* 3 +: 8] = 8'd10;
        window[8*45 +: 8] = 8'd20;
        window[8* 9 +: 8] = 8'd100;
        window[8*39 +: 8] = 8'd200;
        #1;
        if (pair_sums[8:0]   !== 9'd30)  begin $display("FAIL pair0"); errors=errors+1; end
        if (pair_sums[17:9]  !== 9'd300) begin $display("FAIL pair1"); errors=errors+1; end

        if (errors == 0) $display("PASS: all hardcoded cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
