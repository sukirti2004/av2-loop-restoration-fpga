`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// selection_regs.v
//
// Per-RU selection bitmap storage for the RDO combiner. Three NUM_RU-wide
// registers (one per candidate) act as bitmaps indexed by RU number:
//     sel_none[i] = 1 iff RU i selected NONE
//     sel_pc[i]   = 1 iff RU i selected PC
//     sel_ns[i]   = 1 iff RU i selected NS
// For any RU i, exactly one of sel_none[i]/sel_pc[i]/sel_ns[i] is 1.
//
// Uses an internal write counter (wr_idx) that increments on every
// selection_valid pulse. Because cost_compare emits selections in strict RU
// order (RU 0 first, RU 1 second, ...), the counter directly identifies which
// bit to set. Independent of rdo_control's ru_idx_out (which is 4 cycles
// ahead of selection_valid at this point in the pipeline).
//
// `clear` is asserted at the start of each frame -- either by tying to
// rdo_control's sof, or by an AXI-Lite write in the top-level wrapper.
// Resets wr_idx to 0 and all three bitmap regs to 0.
//
// NUM_RU default = 64 : accommodates up to 4K frames (60 RUs at RU=256).
// For 1080p (40 RUs), the upper 24 bits of each register stay 0.
//
// AXI-Lite exposure (in top-level wrapper): each NUM_RU-wide register spans
// ceil(NUM_RU/32) 32-bit AXI-Lite regs. For NUM_RU=64: two 32b regs per
// candidate, 6 regs total (SEL_NONE_LO, SEL_NONE_HI, SEL_PC_LO, ...).
// -----------------------------------------------------------------------------

module selection_regs #(
    parameter integer NUM_RU   = 64,
    parameter integer WR_IDX_W = 6      // ceil(log2(NUM_RU)); 6 for NUM_RU=64
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 clear,             // frame boundary: reset all
    input  wire [1:0]           selection,         // 0=NONE, 1=PC, 2=NS
    input  wire                 selection_valid,   // 1-cycle pulse from cost_compare
    output reg  [NUM_RU-1:0]    sel_none,
    output reg  [NUM_RU-1:0]    sel_pc,
    output reg  [NUM_RU-1:0]    sel_ns,
    output reg  [WR_IDX_W-1:0]  num_ru_processed   // = wr_idx (RUs latched so far)
);

    always @(posedge clk) begin
        if (rst || clear) begin
            sel_none         <= {NUM_RU{1'b0}};
            sel_pc           <= {NUM_RU{1'b0}};
            sel_ns           <= {NUM_RU{1'b0}};
            num_ru_processed <= {WR_IDX_W{1'b0}};
        end else if (selection_valid) begin
            // Variable bit-select on LHS -- legal Verilog-2001 and
            // synthesizable on Xilinx (implements as bit-slice mux/enable).
            sel_none[num_ru_processed] <= (selection == 2'd0);
            sel_pc  [num_ru_processed] <= (selection == 2'd1);
            sel_ns  [num_ru_processed] <= (selection == 2'd2);
            num_ru_processed <= num_ru_processed + 1'b1;
        end
    end

endmodule
