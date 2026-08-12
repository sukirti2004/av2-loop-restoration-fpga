`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 16:37:28
// Design Name: 
// Module Name: mult_adder_tree
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
// mult_adder_tree.v
//
// 12 pair-sums × 12 taps → 12 products → sum → final int20 sum.
// 3 pipeline stages: mul → tree upper half → tree lower half.
// Widths carried at 20-bit signed throughout to avoid truncation.
// -----------------------------------------------------------------------------

module mult_adder_tree (
    input  wire                clk,
    input  wire                rst,        // sync, active high
    input  wire                valid_in,
    input  wire [107:0]        pair_sums,  // 12 × uint9
    input  wire  [83:0]        taps,       // 12 × int7
    output reg                 valid_out,
    output reg  signed [19:0]  sum_out
);

    // ---- Stage 0: input register (Vivado retimes into DSP48 A2REG/B2REG) ----
    reg [107:0] pair_sums_r;
    reg  [83:0] taps_r;
    reg         valid_s0;

    always @(posedge clk) begin
        if (rst) begin
            pair_sums_r <= 108'd0;
            taps_r      <= 84'd0;
            valid_s0    <= 1'b0;
        end else begin
            pair_sums_r <= pair_sums;
            taps_r      <= taps;
            valid_s0    <= valid_in;
        end
    end

    // ---- Stage 1: multipliers (mapped to DSP48 with internal reg) ----
    (* use_dsp = "yes" *) reg signed [19:0] prod [0:11];
    reg               valid_s1;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            valid_s1 <= 1'b0;
            for (i = 0; i < 12; i = i + 1) prod[i] <= 20'sd0;
        end else begin
            valid_s1 <= valid_s0;
            for (i = 0; i < 12; i = i + 1) begin
                prod[i] <= $signed({1'b0, pair_sums_r[9*i +: 9]}) *
                           $signed(taps_r[7*i +: 7]);
            end
        end
    end

    // ---- Stage 2a: four 3-input sums ----
    reg signed [19:0] q0, q1, q2, q3;
    reg               valid_s2a;

    always @(posedge clk) begin
        if (rst) begin
            valid_s2a <= 1'b0;
            q0 <= 20'sd0; q1 <= 20'sd0; q2 <= 20'sd0; q3 <= 20'sd0;
        end else begin
            valid_s2a <= valid_s1;
            q0 <= prod[0] + prod[1]  + prod[2];
            q1 <= prod[3] + prod[4]  + prod[5];
            q2 <= prod[6] + prod[7]  + prod[8];
            q3 <= prod[9] + prod[10] + prod[11];
        end
    end

    // ---- Stage 2b: two 2-input sums ----
    reg signed [19:0] half_a, half_b;
    reg               valid_s2b;

    always @(posedge clk) begin
        if (rst) begin
            valid_s2b <= 1'b0;
            half_a <= 20'sd0; half_b <= 20'sd0;
        end else begin
            valid_s2b <= valid_s2a;
            half_a <= q0 + q1;
            half_b <= q2 + q3;
        end
    end

    // ---- Stage 3: combine halves ----
    always @(posedge clk) begin
        if (rst) begin
            valid_out <= 1'b0;
            sum_out   <= 20'sd0;
        end else begin
            valid_out <= valid_s2b;
            sum_out   <= half_a + half_b;
        end
    end

endmodule
