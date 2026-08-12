`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 18:41:30
// Design Name: 
// Module Name: tb_window_former
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
module tb_window_former;
    reg          clk = 0;
    reg          rst = 1;
    reg          valid_in = 0;
    reg  [55:0]  col_pixels = 0;
    wire         valid_out;
    wire [391:0] window;
    integer      errors = 0;
    integer      r, c, col;
    reg  [7:0]   expected;

    always #5 clk = ~clk;

    window_former dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .col_pixels(col_pixels),
        .valid_out(valid_out), .window(window)
    );

    initial begin
        // Reset
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // 1. valid_out must be low before enough columns arrive
        if (valid_out !== 1'b0) begin
            $display("FAIL: valid_out high before any input"); errors = errors + 1;
        end

        // 2. Feed 7 distinct columns.
        //    On column `col` (1..7), row r gets pixel (col << 4) | r.
        //    After 7 loads, window[r][c] should equal ((c+1) << 4) | r
        //    (col c corresponds to the (c+1)-th column we fed).
        valid_in = 1;
        for (col = 1; col <= 7; col = col + 1) begin
            for (r = 0; r < 7; r = r + 1)
                col_pixels[8*r +: 8] = (col << 4) | r[7:0];
            @(posedge clk); #1;
        end
        valid_in   = 0;
        col_pixels = 0;

        // Now inspect. valid_out should be high (asserted on the 7th edge).
        if (valid_out !== 1'b1) begin
            $display("FAIL: valid_out low after 7 loads"); errors = errors + 1;
        end

        for (r = 0; r < 7; r = r + 1) begin
            for (c = 0; c < 7; c = c + 1) begin
                expected = ((c + 1) << 4) | r[7:0];
                if (window[8*(r*7 + c) +: 8] !== expected) begin
                    $display("FAIL: window[%0d][%0d]=%02x expected %02x",
                             r, c, window[8*(r*7 + c) +: 8], expected);
                    errors = errors + 1;
                end
            end
        end

        // 3. Feed one more column, oldest should shift out.
        valid_in = 1;
        for (r = 0; r < 7; r = r + 1)
            col_pixels[8*r +: 8] = (8'h80) | r[7:0];   // column value 0x8x
        @(posedge clk); #1;
        valid_in   = 0;
        col_pixels = 0;

        // Rightmost column now has 0x8x. Column 0 should now hold what was
        // previously column 1 -> ((1+1)<<4)|r = 0x20 | r
        for (r = 0; r < 7; r = r + 1) begin
            expected = 8'h20 | r[7:0];
            if (window[8*(r*7 + 0) +: 8] !== expected) begin
                $display("FAIL after shift: window[%0d][0]=%02x expected %02x",
                         r, window[8*(r*7 + 0) +: 8], expected); errors = errors + 1;
            end
            expected = 8'h80 | r[7:0];
            if (window[8*(r*7 + 6) +: 8] !== expected) begin
                $display("FAIL after shift: window[%0d][6]=%02x expected %02x",
                         r, window[8*(r*7 + 6) +: 8], expected); errors = errors + 1;
            end
        end

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
