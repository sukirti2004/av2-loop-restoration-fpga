`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 24.06.2026 13:11:44
// Design Name: Filter LUT
// Module Name: filter_lut
// Project Name:
// Target Devices: PYNQ-Z2 (xc7z020)
// Tool Versions: Vivado 2025.2
// Description: Stores filter taps for all 256 filters.
//              Memory is organized as 256 entries x 784-bit (49 taps x 16-bit).
//              One read per clock gives all 49 taps for the requested filter.
//              rom_style="block" forces BRAM inference instead of mux logic.
//
// Dependencies: filter_lut.hex (256 lines, 49 taps per line in Q3.13)
//
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Restructured from flat 12544-entry memory to 256-entry wide
//                 memory to enable BRAM inference and fix F7 Mux overflow.
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////
module filter_lut (
    input  wire        clk,
    input  wire        valid_in,
    input  wire [7:0]  filter_id,
    // All 49 taps packed into one flat bus
    // tap[i] = taps_flat[i*16 +: 16]
    output reg [49*16-1:0] taps_flat,
    output reg             valid_out
);

// 256 filters, each entry holds all 49 taps packed as 784-bit word.
// rom_style="block" tells Vivado to use BRAM instead of LUT logic.
// Vivado automatically instantiates ~22 BRAM36 blocks in parallel
// to achieve the 784-bit data width.
(* rom_style = "block" *) reg [49*16-1:0] mem [0:255];

initial begin
    $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_pc/filter_lut.hex", mem);
end

// Single indexed read - all 49 taps arrive in one clock cycle.
// No loop needed because the wide memory provides all taps at once.
always @(posedge clk) begin
    valid_out <= valid_in;
    if (valid_in)
        taps_flat <= mem[filter_id];
end

endmodule