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
// ns_line_buffer.v — BRAM-friendly refactor
//
// Each memN has exactly 1 read + 1 write per cycle (BRAM-inferable):
//   mem0:  read at ptr, write at ptr           (SDP)
//   memN (N>=1): read at ptr, write at ptr_r   (TDP, ptr_r = ptr delayed 1 cyc)
//
// Cascade uses registered read output (r_{i-1}) instead of a combinational
// read, avoiding the 3-port pattern that forced LUTRAM inference before.
// -----------------------------------------------------------------------------

module ns_line_buffer #(parameter integer W = 1920) (
    input  wire        clk,
    input  wire        rst,
    // start_pulse: 1-cycle pulse from wrapper on each new frame. Without this,
    // fill_done sticks at 1 after Run 1 and valid_out fires immediately on
    // Run N cycle 1 with mem0..mem5 holding Run N-1's bottom rows — output
    // gets phase-shifted by the entire fill window and mixed with stale data.
    // See project_ns_multi_frame_state_carryover.
    input  wire        start_pulse,
    input  wire        valid_in,
    input  wire [7:0]  pixel_in,
    output reg         valid_out,
    output wire [55:0] col_pixels
);

    localparam integer AW           = $clog2(W);
    localparam integer FILL_TARGET  = 6 * W;
    localparam integer FILL_W       = $clog2(FILL_TARGET + 1);

    (* ram_style = "block" *) reg [7:0] mem0 [0:W-1];
    (* ram_style = "block" *) reg [7:0] mem1 [0:W-1];
    (* ram_style = "block" *) reg [7:0] mem2 [0:W-1];
    (* ram_style = "block" *) reg [7:0] mem3 [0:W-1];
    (* ram_style = "block" *) reg [7:0] mem4 [0:W-1];
    (* ram_style = "block" *) reg [7:0] mem5 [0:W-1];

    reg [AW-1:0]      ptr, ptr_r;
    reg [7:0]         r0, r1, r2, r3, r4, r5;
    reg [7:0]         pixel_in_r;
    reg [FILL_W-1:0]  fill_ctr;
    reg               fill_done;

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
            // mem0..mem5 (BRAMs) are NOT reset — they get overwritten as
            // ptr walks through them during the new fill window.
        end else if (valid_in) begin
            // --- Reads at current ptr (one per memory) ---
            r0 <= mem0[ptr];
            r1 <= mem1[ptr];
            r2 <= mem2[ptr];
            r3 <= mem3[ptr];
            r4 <= mem4[ptr];
            r5 <= mem5[ptr];

            // --- Writes ---
            //   mem0 at current ptr (SDP: same-addr read-then-write)
            //   mem1..5 at delayed ptr_r (TDP: separate write address)
            mem0[ptr]   <= pixel_in;
            mem1[ptr_r] <= r0;
            mem2[ptr_r] <= r1;
            mem3[ptr_r] <= r2;
            mem4[ptr_r] <= r3;
            mem5[ptr_r] <= r4;

            pixel_in_r <= pixel_in;

            // Advance ptr, keep ptr_r one cycle behind
            ptr_r <= ptr;
            ptr   <= (ptr == W - 1) ? {AW{1'b0}} : ptr + 1'b1;

            // Fill counter — same target as before, latency is unchanged
            if (!fill_done) begin
                if (fill_ctr == FILL_TARGET - 1) fill_done <= 1'b1;
                else                             fill_ctr  <= fill_ctr + 1'b1;
            end
            valid_out <= fill_done;
        end else begin
            valid_out <= 1'b0;
        end
    end

    // Same output layout as before (drop-in replacement)
    assign col_pixels[ 7: 0] = r5;
    assign col_pixels[15: 8] = r4;
    assign col_pixels[23:16] = r3;
    assign col_pixels[31:24] = r2;
    assign col_pixels[39:32] = r1;
    assign col_pixels[47:40] = r0;
    assign col_pixels[55:48] = pixel_in_r;

endmodule