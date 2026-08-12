`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.06.2026 14:09:16
// Design Name: 
// Module Name: mac_engine
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

module mac_engine (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,

    // 49 pixels from patch, each 8-bit unsigned
    input  wire [49*8-1:0]  pixels_flat,

    // 49 taps from filter LUT, each 16-bit Q3.13 signed
    input  wire [49*16-1:0] taps_flat,

    // output pixel
    output reg  [7:0]  pixel_out,
    output reg         valid_out
);

// accumulator width:
// pixel: 8-bit unsigned (max 255)
// tap:   16-bit signed Q3.13 (max range: [-4.0, +4] -> 32767 in fixed point)
// product: 8 + 16 = 24-bit signed
// sum of 49 products needs 6 more bits headroom
// total accumulator: 30-bit signed
reg signed [29:0] acc;

// extract individual pixels and taps as wires
wire [7:0]        px  [0:48];
wire signed [15:0] tap [0:48];

genvar k;
generate
    for (k = 0; k < 49; k = k + 1) begin : unpack
        assign px[k]  = pixels_flat[k*8  +: 8];
        assign tap[k] = $signed(taps_flat[k*16 +: 16]);
    end
endgenerate

// 49 products computed combinationally
wire signed [23:0] products [0:48];
generate
    for (k = 0; k < 49; k = k + 1) begin : multiply
        assign products[k] = $signed({1'b0, px[k]}) * tap[k];
    end
endgenerate

// sum all 49 products
wire signed [29:0] sum;
assign sum = products[0]  + products[1]  + products[2]  +
             products[3]  + products[4]  + products[5]  +
             products[6]  + products[7]  + products[8]  +
             products[9]  + products[10] + products[11] +
             products[12] + products[13] + products[14] +
             products[15] + products[16] + products[17] +
             products[18] + products[19] + products[20] +
             products[21] + products[22] + products[23] +
             products[24] + products[25] + products[26] +
             products[27] + products[28] + products[29] +
             products[30] + products[31] + products[32] +
             products[33] + products[34] + products[35] +
             products[36] + products[37] + products[38] +
             products[39] + products[40] + products[41] +
             products[42] + products[43] + products[44] +
             products[45] + products[46] + products[47] +
             products[48];

// right shift by 13 to remove Q3.13 scale, then clip to [0,255]
wire signed [29:0] shifted;
assign shifted = sum >>> 13;

always @(posedge clk) begin
    if (!resetn) begin
        pixel_out <= 8'd0;
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_in;
        if (valid_in) begin
            // clip to [0, 255]
            if (shifted > 30'sd255)
                pixel_out <= 8'd255;
            else if (shifted < 30'sd0)
                pixel_out <= 8'd0;
            else
                pixel_out <= shifted[7:0];
        end
    end
end

endmodule
