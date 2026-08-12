`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 21:16:58
// Design Name: 
// Module Name: line_buffer
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
// line_buffer.v
//
// Six W-deep cascaded line delays that turn a raster-scan pixel stream into
// a 7-pixel column each cycle:  {row R, row R-1, ..., row R-6} at some column.
//
// Cascade structure: pixel_in -> mem0 -> mem1 -> mem2 -> mem3 -> mem4 -> mem5,
// where each memN is a circular-buffer FIFO of depth W. Reads are registered.
// pixel_in is registered once so it aligns with out0..out5 (same column).
//
// After 6*W valid_in cycles, valid_out asserts; col_pixels then advances one
// column per valid_in cycle.
//
//   col_pixels layout (low to high): row R-6, R-5, R-4, R-3, R-2, R-1, R
// -----------------------------------------------------------------------------

module line_buffer #(parameter integer W = 1920) (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [7:0]  pixel_in,
    output reg         valid_out,
    output wire [55:0] col_pixels
);

    localparam integer AW           = $clog2(W);
    localparam integer FILL_TARGET  = 6 * W;
    localparam integer FILL_W       = $clog2(FILL_TARGET + 1);

    reg [7:0] mem0 [0:W-1];
    reg [7:0] mem1 [0:W-1];
    reg [7:0] mem2 [0:W-1];
    reg [7:0] mem3 [0:W-1];
    reg [7:0] mem4 [0:W-1];
    reg [7:0] mem5 [0:W-1];

    reg [AW-1:0]      ptr;
    reg [7:0]         out0, out1, out2, out3, out4, out5;
    reg [7:0]         pixel_in_r;
    reg [FILL_W-1:0]  fill_ctr;
    reg               fill_done;

    always @(posedge clk) begin
        if (rst) begin
            ptr        <= {AW{1'b0}};
            fill_ctr   <= {FILL_W{1'b0}};
            fill_done  <= 1'b0;
            valid_out  <= 1'b0;
            pixel_in_r <= 8'd0;
            out0 <= 8'd0; out1 <= 8'd0; out2 <= 8'd0;
            out3 <= 8'd0; out4 <= 8'd0; out5 <= 8'd0;
        end else if (valid_in) begin
            // Registered reads (OLD memory values)
            out0 <= mem0[ptr];
            out1 <= mem1[ptr];
            out2 <= mem2[ptr];
            out3 <= mem3[ptr];
            out4 <= mem4[ptr];
            out5 <= mem5[ptr];

            // Cascaded writes: each memN takes the OLD value of memN-1
            mem0[ptr] <= pixel_in;
            mem1[ptr] <= mem0[ptr];
            mem2[ptr] <= mem1[ptr];
            mem3[ptr] <= mem2[ptr];
            mem4[ptr] <= mem3[ptr];
            mem5[ptr] <= mem4[ptr];

            pixel_in_r <= pixel_in;

            ptr <= (ptr == W - 1) ? {AW{1'b0}} : ptr + 1'b1;

            if (!fill_done) begin
                if (fill_ctr == FILL_TARGET - 1) fill_done <= 1'b1;
                else                             fill_ctr  <= fill_ctr + 1'b1;
            end
            valid_out <= fill_done;
        end else begin
            valid_out <= 1'b0;
        end
    end

    // col_pixels[8*r +: 8]:  r=0 -> row R-6 (oldest),  r=6 -> row R (newest)
    assign col_pixels[ 7: 0] = out5;
    assign col_pixels[15: 8] = out4;
    assign col_pixels[23:16] = out3;
    assign col_pixels[31:24] = out2;
    assign col_pixels[39:32] = out1;
    assign col_pixels[47:40] = out0;
    assign col_pixels[55:48] = pixel_in_r;

endmodule
