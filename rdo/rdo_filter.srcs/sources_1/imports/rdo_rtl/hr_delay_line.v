`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// hr_delay_line.v
//
// Parameterized pixel + valid shift register used to align the HR reference
// stream with each candidate's pipeline latency inside the RDO combiner.
//
// Instantiated 3× in rdo_top:
//   hr_delay_line #(.DELAY(0)) u_hr_none  — HR aligned with SR (no delay)
//   hr_delay_line #(.DELAY(6)) u_hr_pc    — HR aligned with PC output
//   hr_delay_line #(.DELAY(7)) u_hr_ns    — HR aligned with NS output
//
// (Final PC/NS latency values are calibrated in Phase 2 against multi-RU
// golden vectors, same procedure as NS `control.v` ROW_DELAY/COL_DELAY.)
//
// Behavior:
//   DELAY=0  → passthrough (hr_out = hr_in, valid_out = valid_in), combinational
//   DELAY>=1 → registered shift chain, advances on every clock unconditionally.
//              valid_in and hr_in are shifted through together as one packed
//              unit — a bubble (valid_in=0) propagates as valid_out=0 exactly
//              DELAY cycles later. HR and candidate streams are lockstep from
//              their MM2S DMAs, so unconditional advance is correct.
//
// Bit-plan:
//   hr_in, hr_out    : uint8
//   valid_in, valid_out : 1 bit
//   Shift storage    : 8·DELAY + DELAY bits total (~15 FF for DELAY=6)
// -----------------------------------------------------------------------------

module hr_delay_line #(
    parameter integer DELAY = 6
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       valid_in,
    input  wire [7:0] hr_in,
    output wire       valid_out,
    output wire [7:0] hr_out
);

    generate
        if (DELAY == 0) begin : gen_passthrough
            // Combinational passthrough for the NONE candidate — HR arrives
            // in lockstep with SR, no delay needed.
            assign hr_out    = hr_in;
            assign valid_out = valid_in;
        end
        else begin : gen_shift
            reg  [7:0] pixel_pipe [0:DELAY-1];
            reg        valid_pipe [0:DELAY-1];
            integer    idx;

            always @(posedge clk) begin
                if (rst) begin
                    for (idx = 0; idx < DELAY; idx = idx + 1) begin
                        pixel_pipe[idx] <= 8'd0;
                        valid_pipe[idx] <= 1'b0;
                    end
                end else begin
                    // Input at head of chain
                    pixel_pipe[0] <= hr_in;
                    valid_pipe[0] <= valid_in;
                    // Shift the rest
                    for (idx = 1; idx < DELAY; idx = idx + 1) begin
                        pixel_pipe[idx] <= pixel_pipe[idx-1];
                        valid_pipe[idx] <= valid_pipe[idx-1];
                    end
                end
            end

            assign hr_out    = pixel_pipe[DELAY-1];
            assign valid_out = valid_pipe[DELAY-1];
        end
    endgenerate

endmodule
