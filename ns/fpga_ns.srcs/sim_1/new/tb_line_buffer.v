`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 21:17:40
// Design Name: 
// Module Name: tb_line_buffer
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

module tb_line_buffer;
    localparam integer W = 8;

    reg          clk = 0;
    reg          rst = 1;
    reg          valid_in = 0;
    reg  [7:0]   pixel_in = 0;
    wire         valid_out;
    wire [55:0]  col_pixels;
    integer      errors = 0;
    integer      r, c, cyc;
    reg  [55:0]  expected;

    always #5 clk = ~clk;

    line_buffer #(.W(W)) dut (
        .clk(clk), .rst(rst),
        .valid_in(valid_in), .pixel_in(pixel_in),
        .valid_out(valid_out), .col_pixels(col_pixels)
    );

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // Pixel encoding: P(r,c) = (r << 4) | c.  Distinct 0x00..0x77 for 8x8.
        cyc = 0;
        valid_in = 1;
        for (r = 0; r < 8; r = r + 1) begin
            for (c = 0; c < W; c = c + 1) begin
                pixel_in = (r << 4) | c[3:0];
                @(posedge clk); #1;
                cyc = cyc + 1;

                // valid_out must stay low for the first 48 edges (fill period).
                if (cyc <= 48 && valid_out !== 1'b0) begin
                    $display("FAIL cyc=%0d: valid_out high too early", cyc);
                    errors = errors + 1;
                end

                // At edge 49 the just-sampled pixel is P(6,0). col_pixels
                // should now show column 0 of rows 0..6 (row 6 in the top byte).
                if (cyc == 49) begin
                    if (valid_out !== 1'b1) begin
                        $display("FAIL cyc=49: valid_out low"); errors = errors + 1;
                    end
                    expected = {8'h60, 8'h50, 8'h40, 8'h30, 8'h20, 8'h10, 8'h00};
                    if (col_pixels !== expected) begin
                        $display("FAIL cyc=49: got %014h expected %014h",
                                 col_pixels, expected);
                        errors = errors + 1;
                    end
                end

                // Next edge (P(6,1) sampled): col_pixels should be column 1 of
                // rows 0..6.
                if (cyc == 50) begin
                    expected = {8'h61, 8'h51, 8'h41, 8'h31, 8'h21, 8'h11, 8'h01};
                    if (col_pixels !== expected) begin
                        $display("FAIL cyc=50: got %014h expected %014h",
                                 col_pixels, expected);
                        errors = errors + 1;
                    end
                end

                // End of row 6 (P(6,7) sampled at cyc=56): column 7 of rows 0..6.
                if (cyc == 56) begin
                    expected = {8'h67, 8'h57, 8'h47, 8'h37, 8'h27, 8'h17, 8'h07};
                    if (col_pixels !== expected) begin
                        $display("FAIL cyc=56: got %014h expected %014h",
                                 col_pixels, expected);
                        errors = errors + 1;
                    end
                end

                // Start of row 7 (P(7,0) sampled at cyc=57): the OLDEST row
                // now advances from R-6=0 to R-6=1, so col_pixels shows rows 1..7.
                if (cyc == 57) begin
                    expected = {8'h70, 8'h60, 8'h50, 8'h40, 8'h30, 8'h20, 8'h10};
                    if (col_pixels !== expected) begin
                        $display("FAIL cyc=57: got %014h expected %014h",
                                 col_pixels, expected);
                        errors = errors + 1;
                    end
                end
            end
        end
        valid_in = 0;

        // Gap check: valid_out drops when valid_in drops
        @(posedge clk); #1;
        if (valid_out !== 1'b0) begin
            $display("FAIL: valid_out still high after valid_in dropped");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
