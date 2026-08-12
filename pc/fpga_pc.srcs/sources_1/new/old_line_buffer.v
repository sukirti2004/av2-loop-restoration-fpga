`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.06.2026 05:21:35
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

module line_buffer #(
    parameter MAX_W = 1920
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,
    input  wire [7:0]  pixel_in,
    input  wire [10:0] img_width,
    input  wire [10:0] img_height,

    output reg [49*8-1:0] pixels_flat,
    output reg            valid_out
);

reg [7:0] lbuf [0:6][0:MAX_W-1];

reg [10:0] col_cnt;
reg [10:0] row_cnt;
reg [2:0]  wr_buf;

reg [10:0] col_prev;
reg [10:0] row_prev;
reg [2:0]  wr_buf_prev;
reg        valid_prev;

integer r, c;

// ── Stage 1: Write ───────────────────────────────────────────────
always @(posedge clk) begin
    if (!resetn) begin
        col_cnt    <= 0; row_cnt <= 0; wr_buf <= 0;
        valid_prev <= 0;
    end else if (valid_in) begin
        lbuf[wr_buf][col_cnt] <= pixel_in;

        col_prev    <= col_cnt;
        row_prev    <= row_cnt;
        wr_buf_prev <= wr_buf;
        valid_prev  <= 1'b1;

        if (col_cnt == img_width - 1) begin
            col_cnt <= 0;
            wr_buf  <= (wr_buf == 3'd6) ? 3'd0 : wr_buf + 3'd1;
            row_cnt <= row_cnt + 1;
        end else begin
            col_cnt <= col_cnt + 1;
        end
    end else begin
        valid_prev <= 1'b0;
    end
end

// ── Stage 2: Read 7x7 window ─────────────────────────────────────
always @(posedge clk) begin
    if (!resetn) begin
        valid_out <= 0;
    end else if (valid_prev) begin
        // output only when full 7x7 patch is available
        if (row_prev >= 6 && col_prev >= 6) begin
            for (r = 0; r < 7; r = r + 1)
                for (c = 0; c < 7; c = c + 1)
                    pixels_flat[(r*7+c)*8 +: 8] <=
                        lbuf[(wr_buf_prev + 1 + r) % 7]
                             [col_prev - 11'd6 + c];
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end else begin
        valid_out <= 1'b0;
    end
end

endmodule
