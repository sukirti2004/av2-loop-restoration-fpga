`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 22:56:49
// Design Name: 
// Module Name: ns_filter_top
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
// ns_filter_top.v
//
// Top-level NS filter accelerator. Stitches together:
//   line_buffer -> window_former -> pair_summer -> mult_adder_tree
//                                                       -> normalize_saturate
//   tap_reg_file (AXI-Lite side)
//   control (raster tracking + swap pulse)
//
// Input:  AXI-Stream-like  {s_valid, s_sof, s_pixel[7:0]}
// Output: AXI-Stream-like  {m_valid, m_pixel[7:0]}
// AXI-Lite tap writes:     {wr_en, wr_addr[5:0], wr_data[31:0]}
// -----------------------------------------------------------------------------

module ns_filter_top #(
    parameter FRAME_W  = 1920,
    parameter LINE_W   = 1920,      // line-buffer depth; usually = FRAME_W
    parameter RU_SHIFT = 8
)(
    input  wire        clk,
    input  wire        rst,

    // 1-cycle pulse from wrapper on every new-frame start. Routed into
    // line_buffer / window_former / control to clear per-frame state that
    // hardware rst doesn't get to touch (aresetn is persistent across runs).
    // Deliberately NOT routed into tap_reg_file — that would erase the
    // loaded coefficient banks.
    input  wire        start_pulse,

    // Pixel input stream
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire  [7:0] s_pixel,

    // Pixel output stream
    output wire        m_valid,
    output wire  [7:0] m_pixel,

    // AXI-Lite register writes (one-cycle handshake)
    input  wire        wr_en,
    input  wire  [5:0] wr_addr,
    input  wire [31:0] wr_data,

    // Multi-RU tap-bank controls (new for Option 2 double-buffered RAM)
    input  wire  [5:0] wr_bank_idx,    // 0..MAX_BANKS-1; selects inactive-bank slot for writes
    input  wire        flip_bank       // 1-cycle pulse: atomically flip active/inactive banks
);

    // Line buffer -> 7-pixel column
    wire        lb_valid;
    wire [55:0] lb_col_pixels;

    ns_line_buffer #(.W(LINE_W)) u_line_buffer (
        .clk(clk), .rst(rst), .start_pulse(start_pulse),
        .valid_in(s_valid), .pixel_in(s_pixel),
        .valid_out(lb_valid), .col_pixels(lb_col_pixels)
    );

    // Column -> 7x7 window
    wire         wf_valid;
    wire [391:0] wf_window;

    window_former u_window_former (
        .clk(clk), .rst(rst), .start_pulse(start_pulse),
        .valid_in(lb_valid), .col_pixels(lb_col_pixels),
        .valid_out(wf_valid), .window(wf_window)
    );

    // Window -> 12 pair-sums (combinational)
    wire [107:0] ps_pair_sums;

    pair_summer u_pair_summer (
        .window(wf_window),
        .pair_sums(ps_pair_sums)
    );

    // Tap register file — double-buffered coefficient RAM (Option 2)
    wire        swap;
    wire [2:0]  ru_row_now, ru_col_now;
    wire [83:0] taps_live;
    wire [15:0] norm_live;

    tap_reg_file u_tap_reg (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_bank_idx(wr_bank_idx),
        .flip_bank(flip_bank),
        .swap(swap),
        .ru_row_now(ru_row_now),
        .ru_col_now(ru_col_now),
        .taps_live(taps_live), .norm_live(norm_live)
    );

    // Delay norm to match mult_adder_tree's pipeline depth (5 stages between
    // taps input and sum_out). Without this, a swap simultaneously flips taps
    // and norm in tap_reg_file, but sum_in reaching normalize_saturate reflects
    // taps from 5 cycles ago — so for 5 output pixels around every RU boundary,
    // OLD-taps' sum gets multiplied by NEW norm (or vice versa), producing
    // garbage. The same-taps isolation test passes because both RUs share norm
    // then; only when norms differ (e.g. sharpener 10923 vs blur 570) does the
    // corruption become visible.
    reg [15:0] norm_pipe [0:4];
    integer np;
    always @(posedge clk) begin
        if (rst) begin
            for (np = 0; np < 5; np = np + 1) norm_pipe[np] <= 16'd0;
        end else begin
            norm_pipe[0] <= norm_live;
            for (np = 1; np < 5; np = np + 1) norm_pipe[np] <= norm_pipe[np-1];
        end
    end
    wire [15:0] norm_delayed = norm_pipe[4];

    // 12 multiplies + adder tree -> int20 sum
    wire               mat_valid;
    wire signed [19:0] mat_sum;

    mult_adder_tree u_mult_adder_tree (
        .clk(clk), .rst(rst),
        .valid_in(wf_valid),
        .pair_sums(ps_pair_sums),
        .taps(taps_live),
        .valid_out(mat_valid),
        .sum_out(mat_sum)
    );

    // Normalize + round + saturate -> uint8 pixel
    normalize_saturate u_normalize_saturate (
        .clk(clk), .rst(rst),
        .valid_in(mat_valid),
        .sum_in(mat_sum),
        .norm(norm_delayed),
        .valid_out(m_valid),
        .pixel_out(m_pixel)
    );

    // Control: watches raster, pulses swap on RU boundaries (with pipeline-latency delay)
    control #(.FRAME_W(FRAME_W), .LINE_W(LINE_W), .RU_SHIFT(RU_SHIFT)) u_control (
        .clk(clk), .rst(rst), .start_pulse(start_pulse),
        .valid_in(s_valid),
        .sof(s_sof),
        .swap(swap),
        .ru_row_out(ru_row_now),
        .ru_col_out(ru_col_now)
    );

endmodule