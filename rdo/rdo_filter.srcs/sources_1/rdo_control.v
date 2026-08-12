`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// rdo_control.v
//
// RU-boundary tracker for the RDO combiner. Counts valid pixels streaming into
// the RDO combiner and pulses `swap` coincident with the LAST pixel of each RU,
// exactly as required by mse_accumulator's swap contract (see mse_accumulator.v
// header: "swap asserted on the same cycle as the LAST pixel of an RU").
//
// Input contract: tile-order streaming.
//   The PS-orchestrated per-RU workspace buffer is streamed via MM2S DMA one
//   RU at a time, RU_SIZE x RU_SIZE = 65536 valid pixels per RU (for RU=256),
//   in RU-internal raster order. Partial edge RUs must be padded to full size
//   by the PS before dispatch. This module does NOT track (row, col) inside
//   the frame — it only counts valid pixels per RU.
//
// The `swap` signal is broadcast to all 3 mse_accumulator instances (NONE,
// PC, NS). Each accumulator's internal 3-stage pipeline aligns swap with the
// last pixel's contribution — no external delay is needed here.
//
// Behavior:
//   - pixel_ctr counts valid_in cycles, 0 .. (RU_SIZE^2 - 1)
//   - On (pixel_ctr == LAST_IDX && valid_in): pulse swap for 1 cycle,
//     wrap pixel_ctr to 0, increment ru_idx_out
//   - sof (optional safety re-sync) resets pixel_ctr = 0 and ru_idx_out = 0
//   - ru_idx_out is monotonic; wraps only on rst or sof (per design spec —
//     PS reads it as "RUs processed since last frame start" telemetry)
//
// Bit-plan:
//   RU_SIZE_LOG2 = 8   -> RU_SIZE = 256, pixels/RU = 65536
//   PIX_CTR_W    = 16  (2 * RU_SIZE_LOG2)  covers 0..65535
//   RU_IDX_W     = 6   supports up to 64 RUs/frame (40 for 1080p at RU=256)
// -----------------------------------------------------------------------------

module rdo_control #(
    parameter integer RU_SIZE_LOG2 = 8,
    parameter integer RU_IDX_W     = 6
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                valid_in,
    input  wire                sof,          // optional re-sync; pulse w/ first pixel of frame
    output wire                swap,         // combinational; asserted with LAST pixel of each RU
    output reg [RU_IDX_W-1:0]  ru_idx_out
);

    // Pixel counter is 2*RU_SIZE_LOG2 bits wide -> exactly wraps at RU_SIZE^2.
    localparam integer PIX_CTR_W = 2 * RU_SIZE_LOG2;

    // LAST_IDX = 2^PIX_CTR_W - 1  (all-ones of PIX_CTR_W bits).
    // Written as a bit-replicated constant so it stays correct if RU_SIZE_LOG2
    // is retargeted to a different RU size in the future.
    wire [PIX_CTR_W-1:0] LAST_IDX = {PIX_CTR_W{1'b1}};

    reg [PIX_CTR_W-1:0] pixel_ctr;

    // Combinational swap: fires on the SAME cycle valid_in delivers the RU's
    // final pixel. This is REQUIRED by mse_accumulator's contract, which
    // latches `s1_swap <= swap` only when `valid_in=1`. A registered swap
    // would land one cycle late (alongside the NEXT RU's first pixel) and
    // corrupt every RU's total by exactly one pixel.
    assign swap = valid_in && (pixel_ctr == LAST_IDX);

    always @(posedge clk) begin
        if (rst) begin
            pixel_ctr  <= {PIX_CTR_W{1'b0}};
            ru_idx_out <= {RU_IDX_W{1'b0}};
        end else if (sof) begin
            // Safety re-sync. If sof coincides with the first valid pixel of a
            // new frame, that pixel gets counted (pixel_ctr <= 1); otherwise
            // pixel_ctr is simply cleared.
            pixel_ctr  <= valid_in ? {{(PIX_CTR_W-1){1'b0}}, 1'b1}
                                   : {PIX_CTR_W{1'b0}};
            ru_idx_out <= {RU_IDX_W{1'b0}};
        end else begin
            if (valid_in) begin
                if (pixel_ctr == LAST_IDX) begin
                    pixel_ctr  <= {PIX_CTR_W{1'b0}};
                    ru_idx_out <= ru_idx_out + 1'b1;
                end else begin
                    pixel_ctr <= pixel_ctr + 1'b1;
                end
            end
        end
    end

endmodule
