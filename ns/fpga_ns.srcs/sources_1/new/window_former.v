`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 18:40:27
// Design Name: 
// Module Name: window_former
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

// -----------------------------------------------------------------------------
// window_former.v
//
// 7x7 shift-register window. Each cycle takes one column of 7 pixels
// (top row in the high byte, bottom row in the low byte) and shifts
// the previous 6 columns left. After 7 valid loads, valid_out asserts
// and `window` holds the full 7x7 in row-major order.
//
//   window bits: cell (row r, col c) -> [8*(r*7 + c) +: 8]
//   col_pixels bits: row r pixel     -> [8*r +: 8]
// -----------------------------------------------------------------------------

module window_former (
    input  wire         clk,
    input  wire         rst,
    // start_pulse: 1-cycle pulse from wrapper on each new frame. Without this,
    // col_count saturates at 7 after Run 1 and valid_out fires immediately on
    // Run N cycle 1 with px[][] still holding Run N-1's final window — stale
    // windows leak into the multiplier stage before real data arrives.
    // See project_ns_multi_frame_state_carryover.
    input  wire         start_pulse,
    input  wire         valid_in,
    input  wire [55:0]  col_pixels,     // 7 pixels, one per row
    output reg          valid_out,
    output wire [391:0] window
);

    reg [7:0] px [0:6][0:6];           // px[row][col], col 6 is rightmost (newest)
    reg [2:0] col_count;               // 0..7, saturates at 7

    integer r, c;

    always @(posedge clk) begin
        if (rst || start_pulse) begin
            // px[][] not cleared — refills naturally in 7 cycles, gated by
            // col_count so downstream never observes the stale contents.
            col_count <= 3'd0;
            valid_out <= 1'b0;
        end else if (valid_in) begin
            // Shift each row one column to the left, load new rightmost column.
            for (r = 0; r < 7; r = r + 1) begin
                for (c = 0; c < 6; c = c + 1)
                    px[r][c] <= px[r][c+1];
                px[r][6] <= col_pixels[8*r +: 8];
            end
            if (col_count < 3'd7) col_count <= col_count + 3'd1;
            valid_out <= (col_count >= 3'd6);
        end else begin
            valid_out <= 1'b0;
        end
    end

    // Flatten to output bus in row-major order.
    genvar gr, gc;
    generate
        for (gr = 0; gr < 7; gr = gr + 1) begin : g_row
            for (gc = 0; gc < 7; gc = gc + 1) begin : g_col
                assign window[8*(gr*7 + gc) +: 8] = px[gr][gc];
            end
        end
    endgenerate

endmodule
