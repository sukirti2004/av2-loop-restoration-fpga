`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 25.06.2026 15:00:30
// Design Name: 
// Module Name: features_compute
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

module feature_compute (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,

    // 49 pixels from 7x7 patch, row-major order
    // pixel(r,c) = pixels_flat[(r*7+c)*8 +: 8]
    input  wire [49*8-1:0] pixels_flat,

    // 4 feature values, Q2.14 signed
    output reg signed [15:0] feat0,  // horizontal
    output reg signed [15:0] feat1,  // vertical
    output reg signed [15:0] feat2,  // diagonal
    output reg signed [15:0] feat3,  // anti-diagonal
    output reg               valid_out
);

// unpack pixels into 1D array
// access pixel(r,c) as px[r*7+c]
wire [7:0] px [0:48];
genvar k;
generate
    for (k = 0; k < 49; k = k + 1) begin : unpack
        assign px[k] = pixels_flat[k*8 +: 8];
    end
endgenerate

// compute laplacians at 25 interior positions (r=1..5, c=1..5)
// 11-bit signed: range [-510, +510]
wire signed [10:0] lap_h [0:24];
wire signed [10:0] lap_v [0:24];
wire signed [10:0] lap_d [0:24];
wire signed [10:0] lap_a [0:24];

genvar gr, gc;
generate
    for (gr = 1; gr <= 5; gr = gr + 1) begin : row_loop
        for (gc = 1; gc <= 5; gc = gc + 1) begin : col_loop

            // center pixel index in flat array
            // horizontal neighbors: ctr-1, ctr+1
            // vertical neighbors:   ctr-7, ctr+7
            // diagonal neighbors:   ctr-8, ctr+8
            // anti-diag neighbors:  ctr-6, ctr+6

            assign lap_h[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[gr*7+gc-1]}) +
                ($signed({1'b0, px[gr*7+gc]}) << 1) -
                $signed({1'b0, px[gr*7+gc+1]});

            assign lap_v[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+gc]}) +
                ($signed({1'b0, px[gr*7+gc]}) << 1) -
                $signed({1'b0, px[(gr+1)*7+gc]});

            assign lap_d[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+(gc-1)]}) +
                ($signed({1'b0, px[gr*7+gc]}) << 1) -
                $signed({1'b0, px[(gr+1)*7+(gc+1)]});

            assign lap_a[(gr-1)*5+(gc-1)] =
                -$signed({1'b0, px[(gr-1)*7+(gc+1)]}) +
                ($signed({1'b0, px[gr*7+gc]}) << 1) -
                $signed({1'b0, px[(gr+1)*7+(gc-1)]});
        end
    end
endgenerate

// absolute values
wire [10:0] abs_h [0:24];
wire [10:0] abs_v [0:24];
wire [10:0] abs_d [0:24];
wire [10:0] abs_a [0:24];

genvar j;
generate
    for (j = 0; j < 25; j = j + 1) begin : abs_comp
        assign abs_h[j] = lap_h[j][10] ? -lap_h[j] : lap_h[j];
        assign abs_v[j] = lap_v[j][10] ? -lap_v[j] : lap_v[j];
        assign abs_d[j] = lap_d[j][10] ? -lap_d[j] : lap_d[j];
        assign abs_a[j] = lap_a[j][10] ? -lap_a[j] : lap_a[j];
    end
endgenerate

// sum 25 absolute values - max = 25 x 510 = 12750, needs 14 bits
wire [13:0] sum_h, sum_v, sum_d, sum_a;

assign sum_h = abs_h[0] +abs_h[1] +abs_h[2] +abs_h[3] +abs_h[4] +
               abs_h[5] +abs_h[6] +abs_h[7] +abs_h[8] +abs_h[9] +
               abs_h[10]+abs_h[11]+abs_h[12]+abs_h[13]+abs_h[14]+
               abs_h[15]+abs_h[16]+abs_h[17]+abs_h[18]+abs_h[19]+
               abs_h[20]+abs_h[21]+abs_h[22]+abs_h[23]+abs_h[24];

assign sum_v = abs_v[0] +abs_v[1] +abs_v[2] +abs_v[3] +abs_v[4] +
               abs_v[5] +abs_v[6] +abs_v[7] +abs_v[8] +abs_v[9] +
               abs_v[10]+abs_v[11]+abs_v[12]+abs_v[13]+abs_v[14]+
               abs_v[15]+abs_v[16]+abs_v[17]+abs_v[18]+abs_v[19]+
               abs_v[20]+abs_v[21]+abs_v[22]+abs_v[23]+abs_v[24];

assign sum_d = abs_d[0] +abs_d[1] +abs_d[2] +abs_d[3] +abs_d[4] +
               abs_d[5] +abs_d[6] +abs_d[7] +abs_d[8] +abs_d[9] +
               abs_d[10]+abs_d[11]+abs_d[12]+abs_d[13]+abs_d[14]+
               abs_d[15]+abs_d[16]+abs_d[17]+abs_d[18]+abs_d[19]+
               abs_d[20]+abs_d[21]+abs_d[22]+abs_d[23]+abs_d[24];

assign sum_a = abs_a[0] +abs_a[1] +abs_a[2] +abs_a[3] +abs_a[4] +
               abs_a[5] +abs_a[6] +abs_a[7] +abs_a[8] +abs_a[9] +
               abs_a[10]+abs_a[11]+abs_a[12]+abs_a[13]+abs_a[14]+
               abs_a[15]+abs_a[16]+abs_a[17]+abs_a[18]+abs_a[19]+
               abs_a[20]+abs_a[21]+abs_a[22]+abs_a[23]+abs_a[24];

// convert to Q2.14:
// feat = sum / (25 x 255) x 2^14 = sum x 21049 >> 13
// 21049/8192 = 2.5694 ≈ 16384/6375 = 2.5694 (< 0.02% error)
wire [29:0] scale_h, scale_v, scale_d, scale_a;

assign scale_h = sum_h * 16'd21049;
assign scale_v = sum_v * 16'd21049;
assign scale_d = sum_d * 16'd21049;
assign scale_a = sum_a * 16'd21049;

always @(posedge clk) begin
    if (!resetn) begin
        feat0     <= 16'd0;
        feat1     <= 16'd0;
        feat2     <= 16'd0;
        feat3     <= 16'd0;
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_in;
        if (valid_in) begin
            feat0 <= scale_h[28:13];
            feat1 <= scale_v[28:13];
            feat2 <= scale_d[28:13];
            feat3 <= scale_a[28:13];
        end
    end
end

endmodule
