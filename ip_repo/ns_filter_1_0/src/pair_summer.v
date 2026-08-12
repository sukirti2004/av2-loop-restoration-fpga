`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 16:24:58
// Design Name: 
// Module Name: pair_summer
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
// pair_summer.v
//
// Takes the 7x7 window and produces 12 outputs:
//   - 11 mirror-pair sums (uint9 each, since uint8 + uint8 = up to 510)
//   - 1 center-cell passthrough (uint8 zero-extended to uint9)
//
// Pure combinational. No clock, no reset.
// -----------------------------------------------------------------------------

module pair_summer (
    // Flattened 7x7 window: cell i occupies bits [8*i +: 8].
    // Row-major flat index 0..48.
    input  wire [391:0] window,

    // 12 pair-sums, each 9 bits.
    // out i occupies bits [9*i +: 9].
    output wire [107:0] pair_sums
);

    // Convenience: extract each 8-bit pixel by flat index.
    wire [7:0] px [0:48];
    genvar gi;
    generate
        for (gi = 0; gi < 49; gi = gi + 1) begin : g_extract
            assign px[gi] = window[8*gi +: 8];
        end
    endgenerate

    // The 11 mirror pairs + center singleton.
    // Zero-extend each 8-bit pixel to 9 bits before adding.
    wire [8:0] s [0:11];

    assign s[ 0] = {1'b0, px[ 3]} + {1'b0, px[45]};   // pair 0
    assign s[ 1] = {1'b0, px[ 9]} + {1'b0, px[39]};   // pair 1
    assign s[ 2] = {1'b0, px[10]} + {1'b0, px[38]};   // pair 2
    assign s[ 3] = {1'b0, px[11]} + {1'b0, px[37]};   // pair 3
    assign s[ 4] = {1'b0, px[15]} + {1'b0, px[33]};   // pair 4
    assign s[ 5] = {1'b0, px[16]} + {1'b0, px[32]};   // pair 5
    assign s[ 6] = {1'b0, px[17]} + {1'b0, px[31]};   // pair 6
    assign s[ 7] = {1'b0, px[18]} + {1'b0, px[30]};   // pair 7
    assign s[ 8] = {1'b0, px[19]} + {1'b0, px[29]};   // pair 8
    assign s[ 9] = {1'b0, px[22]} + {1'b0, px[26]};   // pair 9
    assign s[10] = {1'b0, px[23]} + {1'b0, px[25]};   // pair 10
    assign s[11] = {1'b0, px[24]};                    // center singleton

    // Flatten to output bus.
    generate
        for (gi = 0; gi < 12; gi = gi + 1) begin : g_pack
            assign pair_sums[9*gi +: 9] = s[gi];
        end
    endgenerate

endmodule