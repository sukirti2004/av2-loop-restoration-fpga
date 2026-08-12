`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// cost_compare.v
//
// Rate-Distortion cost computation and argmin selection for the RDO combiner.
//
// For each candidate (NONE, PC, NS) computes:
//     cost_x = mse_x + lambda * r_x
// then picks the candidate with the smallest cost. The winner is emitted on
// `selection` with a single-cycle `selection_valid` pulse.
//
// Inputs (mse_x, mse_valid) come from the three mse_accumulator instances.
// Since all three accumulators share the same `swap` signal from rdo_control
// and have identical 3-stage pipelines, their `mse_valid` pulses are always
// coincident -- one shared `mse_valid` input is sufficient (wired from any
// one accumulator's mse_valid output at rdo_top).
//
// lambda / r_x come from AXI-Lite writable registers in the top-level wrapper;
// here they are treated as continuously-valid inputs. They must be stable at
// least from the mse_valid pulse until 2 cycles later (i.e., during both
// pipeline stages). In practice they are static per-frame, so this is trivial.
//
// Pipeline (2 stages, 1-cycle net latency from mse_valid to selection_valid):
//   Posedge N   (mse_valid=1 sampled)    : cost_x_r <= mse_x + lambda*r_x
//                                          stage1_valid <= 1
//   Posedge N+1 (stage1_valid=1 sampled) : selection <= argmin(cost_x_r)
//                                          selection_valid <= 1  (single-cycle pulse)
// So selection_valid rises one clock period after mse_valid rises.
//
// Tie-break: NONE > PC > NS. Prefer least filtering when costs match.
//
// Bit-plan:
//   mse_x                 : uint33  (max 4.27e9 per RU at 256x256)
//   lambda, r_x           : uint16 each
//   lambda * r_x          : uint32  (max 4.29e9)
//   cost_x = mse + lambda*r : uint34  (max 8.56e9, fits 2^34 = 1.71e10)
//   selection             : uint2   (00=NONE, 01=PC, 10=NS)
// -----------------------------------------------------------------------------

module cost_compare (
    input  wire        clk,
    input  wire        rst,

    // MSE inputs from mse_accumulator instances (all 3 valid simultaneously)
    input  wire [32:0] mse_none,
    input  wire [32:0] mse_pc,
    input  wire [32:0] mse_ns,
    input  wire        mse_valid,

    // Rate cost parameters (static per frame; from AXI-Lite regs upstream)
    input  wire [15:0] lambda,
    input  wire [15:0] r_none,
    input  wire [15:0] r_pc,
    input  wire [15:0] r_ns,

    // Winner selection
    output reg  [1:0]  selection,        // 0=NONE, 1=PC, 2=NS
    output reg         selection_valid   // 1-cycle pulse
);

    // =========================================================================
    // Stage 1: cost = mse + lambda * r
    // Multiply is combinational (16x16 -> 32b, one DSP48 per candidate).
    // Adder is 33+32 -> 34 (zero-extend both to 34).
    // =========================================================================
    wire [31:0] lprod_none_c = lambda * r_none;
    wire [31:0] lprod_pc_c   = lambda * r_pc;
    wire [31:0] lprod_ns_c   = lambda * r_ns;

    wire [33:0] cost_none_c = {1'b0, mse_none} + {2'b00, lprod_none_c};
    wire [33:0] cost_pc_c   = {1'b0, mse_pc  } + {2'b00, lprod_pc_c  };
    wire [33:0] cost_ns_c   = {1'b0, mse_ns  } + {2'b00, lprod_ns_c  };

    reg [33:0] cost_none_r;
    reg [33:0] cost_pc_r;
    reg [33:0] cost_ns_r;
    reg        stage1_valid;

    always @(posedge clk) begin
        if (rst) begin
            cost_none_r  <= 34'd0;
            cost_pc_r    <= 34'd0;
            cost_ns_r    <= 34'd0;
            stage1_valid <= 1'b0;
        end else begin
            stage1_valid <= mse_valid;
            if (mse_valid) begin
                cost_none_r <= cost_none_c;
                cost_pc_r   <= cost_pc_c;
                cost_ns_r   <= cost_ns_c;
            end
        end
    end

    // =========================================================================
    // Stage 2: argmin over the 3 registered costs
    //   NONE wins iff cost_none <= cost_pc AND cost_none <= cost_ns
    //   else PC wins iff cost_pc <= cost_ns
    //   else NS
    // Tie priority: NONE > PC > NS (encoded via <= comparisons).
    // =========================================================================
    wire none_le_pc = (cost_none_r <= cost_pc_r);
    wire none_le_ns = (cost_none_r <= cost_ns_r);
    wire pc_le_ns   = (cost_pc_r   <= cost_ns_r);

    always @(posedge clk) begin
        if (rst) begin
            selection       <= 2'd0;
            selection_valid <= 1'b0;
        end else begin
            selection_valid <= stage1_valid;
            if (stage1_valid) begin
                if (none_le_pc && none_le_ns) begin
                    selection <= 2'd0;   // NONE
                end else if (pc_le_ns) begin
                    selection <= 2'd1;   // PC
                end else begin
                    selection <= 2'd2;   // NS
                end
            end
        end
    end

endmodule
