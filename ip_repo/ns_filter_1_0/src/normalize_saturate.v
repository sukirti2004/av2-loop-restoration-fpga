`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 17:01:15
// Design Name: 
// Module Name: normalize_saturate
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
// normalize_saturate.v
//
// Multiplies the int20 adder-tree sum by the uint16 Q0.16 norm factor,
// applies round-half-up divide-by-65536 (add 2^15 then arithmetic >> 16),
// and saturates the result to uint8.
//
// Pipeline: 2 stages (norm mul → round+shift+saturate).
// -----------------------------------------------------------------------------

module normalize_saturate (
    input  wire                clk,
    input  wire                rst,
    input  wire                valid_in,
    input  wire signed [19:0]  sum_in,     // from mult_adder_tree
    input  wire        [15:0]  norm,       // uint16, Q0.16
    output reg                 valid_out,
    output reg          [7:0]  pixel_out
);

    // ---- Stage 1: normalization multiply (DSP48 with internal reg) ----
    reg signed [36:0] mult_result;
    reg               valid_s1;

    always @(posedge clk) begin
        if (rst) begin
            valid_s1    <= 1'b0;
            mult_result <= 37'sd0;
        end else begin
            valid_s1    <= valid_in;
            // 20-bit signed × 17-bit (zero-extended unsigned) → 37-bit signed
            mult_result <= sum_in * $signed({1'b0, norm});
        end
    end

    // ---- Combinational round + arithmetic shift right by 16 ----
    wire signed [36:0] rounded = mult_result + 37'sd32768;   // + 2^15
    wire signed [20:0] shifted = rounded >>> 16;             // arithmetic shift

    // ---- Stage 2: saturate to uint8 and register output ----
    always @(posedge clk) begin
        if (rst) begin
            valid_out <= 1'b0;
            pixel_out <= 8'd0;
        end else begin
            valid_out <= valid_s1;
            if (shifted < 21'sd0)
                pixel_out <= 8'd0;
            else if (shifted > 21'sd255)
                pixel_out <= 8'd255;
            else
                pixel_out <= shifted[7:0];
        end
    end

endmodule
