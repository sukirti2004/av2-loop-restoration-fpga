`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 16.07.2026 21:16:58
// Design Name:
// Module Name: ns_line_buffer
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
// ns_line_buffer.v — runtime-width variant
//
// MAX_W is the BRAM depth cap (widest frame the IP will ever run).
// img_width is a runtime input that sets the actual per-frame wrap point and
// fill target. Must be stable across a frame; latched in ns_filter_top on
// start_pulse. See project_ns_multi_frame_state_carryover for start_pulse.
// -----------------------------------------------------------------------------

module ns_line_buffer #(parameter integer MAX_W = 1920) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start_pulse,
    input  wire [10:0] img_width,     // runtime frame width (<= MAX_W)
    input  wire        valid_in,
    input  wire [7:0]  pixel_in,
    output reg         valid_out,
    output wire [55:0] col_pixels
);

    localparam integer AW       = $clog2(MAX_W);
    localparam integer MAX_FILL = 6 * MAX_W;
    localparam integer FILL_W   = $clog2(MAX_FILL + 1);

    (* ram_style = "block" *) reg [7:0] mem0 [0:MAX_W-1];
    (* ram_style = "block" *) reg [7:0] mem1 [0:MAX_W-1];
    (* ram_style = "block" *) reg [7:0] mem2 [0:MAX_W-1];
    (* ram_style = "block" *) reg [7:0] mem3 [0:MAX_W-1];
    (* ram_style = "block" *) reg [7:0] mem4 [0:MAX_W-1];
    (* ram_style = "block" *) reg [7:0] mem5 [0:MAX_W-1];

    reg [AW-1:0]      ptr, ptr_r;
    reg [7:0]         r0, r1, r2, r3, r4, r5;
    reg [7:0]         pixel_in_r;
    reg [FILL_W-1:0]  fill_ctr;
    reg               fill_done;

    // 6 rows × img_width - 1 — REGISTERED to break the combinational multiply
    // out of the fill-done comparator path (100 MHz WNS timing fix 2026-08-14).
    // img_width is quasi-static (only changes on start_pulse in ns_filter_top),
    // so a 1-cycle latency here is invisible before the first fill event.
    reg [FILL_W-1:0] fill_target_m1_r;
    always @(posedge clk) begin
        if (rst) fill_target_m1_r <= {FILL_W{1'b0}};
        else     fill_target_m1_r <= 6 * img_width - 1'b1;
    end

    always @(posedge clk) begin
        if (rst || start_pulse) begin
            ptr        <= {AW{1'b0}};
            ptr_r      <= {AW{1'b0}};
            r0 <= 8'd0; r1 <= 8'd0; r2 <= 8'd0;
            r3 <= 8'd0; r4 <= 8'd0; r5 <= 8'd0;
            pixel_in_r <= 8'd0;
            fill_ctr   <= {FILL_W{1'b0}};
            fill_done  <= 1'b0;
            valid_out  <= 1'b0;
        end else if (valid_in) begin
            r0 <= mem0[ptr];
            r1 <= mem1[ptr];
            r2 <= mem2[ptr];
            r3 <= mem3[ptr];
            r4 <= mem4[ptr];
            r5 <= mem5[ptr];

            mem0[ptr]   <= pixel_in;
            mem1[ptr_r] <= r0;
            mem2[ptr_r] <= r1;
            mem3[ptr_r] <= r2;
            mem4[ptr_r] <= r3;
            mem5[ptr_r] <= r4;

            pixel_in_r <= pixel_in;

            ptr_r <= ptr;
            ptr   <= (ptr == img_width - 1'b1) ? {AW{1'b0}} : ptr + 1'b1;

            if (!fill_done) begin
                if (fill_ctr == fill_target_m1_r) fill_done <= 1'b1;
                else                              fill_ctr  <= fill_ctr + 1'b1;
            end
            valid_out <= fill_done;
        end else begin
            valid_out <= 1'b0;
        end
    end

    assign col_pixels[ 7: 0] = r5;
    assign col_pixels[15: 8] = r4;
    assign col_pixels[23:16] = r3;
    assign col_pixels[31:24] = r2;
    assign col_pixels[39:32] = r1;
    assign col_pixels[47:40] = r0;
    assign col_pixels[55:48] = pixel_in_r;

endmodule
