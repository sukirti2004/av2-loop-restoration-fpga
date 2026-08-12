`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// tap_reg_file.v — double-buffered coefficient RAM (Option 2 architecture).
//
// Stores TWO banks of MAX_BANKS tap sets each. One bank is "active" (feeding
// the filter datapath); the other is "inactive" (available for the PS to
// write next-frame taps into without disturbing current output).
//
// On each RU-boundary `swap` pulse, live taps get populated from
//   active_bank[ ru_row_now * MAX_RU_COLS + ru_col_now ]
// so different RUs use different taps automatically — no per-boundary PS
// intervention required.
//
// PS flow per frame:
//   1) For each RU (r, c):
//        a. Set wr_bank_idx = r*MAX_RU_COLS + c   (via wrapper 0x3C bits [13:8])
//        b. Write 12 taps (0x00..0x2C) and norm (0x30). Writes land in the
//           INACTIVE bank at index wr_bank_idx.
//   2) Pulse flip_bank (0x3C bit 1) → active/inactive roles swap.
//   3) Pulse start_pulse (0x3C bit 0) → frame streams.
//   4) (Optional) load NEXT frame's taps into now-inactive bank while
//      current frame streams — this is the double-buffering win.
//
// IMPORTANT: PS must NOT pulse flip_bank mid-frame. There is no hardware
// interlock. Doing so would swap which bank the swap-pulses read from,
// corrupting outputs. Only flip when the previous frame's TLAST has fired
// AND before the next start_pulse.
// -----------------------------------------------------------------------------

module tap_reg_file #(
    parameter integer MAX_BANKS   = 64    // 40 needed for 1080p; 64 for headroom
    // MAX_RU_COLS is fixed at 8 by the {ru_row_now, ru_col_now} concatenation
    // below (row*8 + col). If ever supporting non-power-of-2 or !=8 columns,
    // switch to explicit multiply.
)(
    input  wire        clk,
    input  wire        rst,

    // AXI-Lite write port — writes always target the INACTIVE bank at wr_bank_idx
    input  wire        wr_en,
    input  wire  [5:0] wr_addr,
    input  wire [31:0] wr_data,
    input  wire  [5:0] wr_bank_idx,       // 0..MAX_BANKS-1; from wrapper 0x3C[13:8]

    // Atomic active/inactive bank flip (single-cycle pulse)
    input  wire        flip_bank,

    // RU-boundary swap (from control.v, ROW_DELAY/COL_DELAY calibrated)
    input  wire        swap,
    input  wire  [2:0] ru_row_now,
    input  wire  [2:0] ru_col_now,

    // Live outputs to datapath
    output wire [83:0] taps_live,
    output wire [15:0] norm_live
);

    // Two banks. bank_taps[0] and bank_taps[1] each hold MAX_BANKS tap sets.
    // Vivado will map this to distributed RAM / LUTRAM.
    reg [6:0]  bank_taps [0:1][0:MAX_BANKS-1][0:11];
    reg [15:0] bank_norm [0:1][0:MAX_BANKS-1];
    reg [6:0]  taps_live_r [0:11];
    reg [15:0] norm_live_r;
    reg        active_bank_r;

    // Writes go to the currently-inactive bank
    wire wr_bank_which = ~active_bank_r;

    // Read index = ru_row * 8 + ru_col, done via bit concatenation (both 3-bit).
    // Valid for up to 8 col RUs (1080p at RU=256: exactly 8).
    wire [5:0] rd_ru_idx = {ru_row_now, ru_col_now};

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            active_bank_r <= 1'b0;
            for (i = 0; i < 12; i = i + 1) taps_live_r[i] <= 7'd0;
            norm_live_r <= 16'd0;
            // bank_taps / bank_norm intentionally not reset here — Vivado
            // will initialize to 0 at power-on, and PS must load valid
            // banks before start_pulse anyway.
        end else begin
            // AXI-Lite write into inactive bank.
            // No range guard on wr_bank_idx — caller (PS) is trusted to keep it
            // within [0, MAX_BANKS). Guard was previously `< MAX_BANKS[5:0]`,
            // but MAX_BANKS=64 sliced to 6 bits = 0, so no writes ever landed.
            if (wr_en) begin
                if (wr_addr < 6'd12)
                    bank_taps[wr_bank_which][wr_bank_idx][wr_addr[3:0]] <= wr_data[6:0];
                else if (wr_addr == 6'd12)
                    bank_norm[wr_bank_which][wr_bank_idx] <= wr_data[15:0];
            end

            // Frame-level active/inactive flip
            if (flip_bank) active_bank_r <= ~active_bank_r;

            // RU-boundary swap: load live from active bank at current RU index.
            // Uses nonblocking semantics: if flip and swap fire same cycle,
            // swap sees the OLD active_bank_r — safe because PS is disciplined
            // to only flip between frames (never mid-frame).
            if (swap) begin
                for (i = 0; i < 12; i = i + 1)
                    taps_live_r[i] <= bank_taps[active_bank_r][rd_ru_idx][i];
                norm_live_r <= bank_norm[active_bank_r][rd_ru_idx];
            end
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < 12; gi = gi + 1) begin : g_pack
            assign taps_live[7*gi +: 7] = taps_live_r[gi];
        end
    endgenerate

    assign norm_live = norm_live_r;

endmodule
