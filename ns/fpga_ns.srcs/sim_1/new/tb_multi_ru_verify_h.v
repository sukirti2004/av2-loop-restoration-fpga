`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 21.07.2026 10:23:31
// Design Name: 
// Module Name: tb_multi_ru_verify_h
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


module tb_multi_ru_verify_h;

    // HORIZONTAL boundary test: 256 rows x 512 cols, 2 RUs side-by-side.
    localparam H       = 256;
    localparam W       = 512;
    localparam RU_SIZE = 256;

    reg clk = 0;  always #3.333 clk = ~clk;
    reg rst = 1;

    reg         s_valid = 0;
    reg         s_sof   = 0;
    reg  [7:0]  s_pixel = 0;
    wire        m_valid;
    wire [7:0]  m_pixel;

    reg         wr_en   = 0;
    reg  [5:0]  wr_addr = 0;
    reg  [31:0] wr_data = 0;

    ns_filter_top #(.FRAME_W(W), .LINE_W(W), .RU_SHIFT(8)) dut (
        .clk(clk), .rst(rst),
        .s_valid(s_valid), .s_sof(s_sof), .s_pixel(s_pixel),
        .m_valid(m_valid), .m_pixel(m_pixel),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );

    reg [7:0] input_img    [0:H*W-1];
    reg [7:0] expected_img [0:H*W-1];
    reg [7:0] captured_img [0:H*W-1];
    // 2 RU * (12 taps + 1 norm-line) = 26 lines, norm stored as 2 bytes so
    // actually the .hex has 12 tap-bytes + 2 norm-bytes per RU = 14 lines * 2 = 28
    reg [7:0] tap_stream   [0:27];

    integer i, err_count, out_ptr;
    integer base, k;
    reg [15:0] norm_val;

    // ---- probes ----
    integer swap_event_count       = 0;
    integer input_pixel_count      = 0;
    integer swap_at_input_raster   [0:15];
    integer swap_at_out_ptr        [0:15];
    integer live_change_count      = 0;
    integer live_change_at_k       [0:15];
    reg [6:0] prev_live_tap0       = 7'h55;
    reg [6:0] prev_live_tap11      = 7'h55;

    // ---- inline task: writes taps k=0..11 to addr k, norm to addr 12 ----
    task write_ru_taps(input integer ru);
        begin
            base = ru * 14;  // 12 tap-bytes + 2 norm-bytes per RU
            for (k = 0; k < 12; k = k + 1) begin
                @(posedge clk);
                wr_en   <= 1'b1;
                wr_addr <= k[5:0];
                wr_data <= {25'b0, tap_stream[base + k][6:0]};
            end
            @(posedge clk);
            wr_en    <= 1'b1;
            wr_addr  <= 6'd12;
            norm_val  = {tap_stream[base+12], tap_stream[base+13]};
            wr_data  <= {16'b0, norm_val};
            @(posedge clk);
            wr_en <= 1'b0;
        end
    endtask

    // ---- capture ----
    always @(posedge clk) begin
        if (!rst && m_valid && out_ptr < H*W) begin
            captured_img[out_ptr] <= m_pixel;
            out_ptr <= out_ptr + 1;
        end
    end

    // ---- probe: count input pixels streamed ----
    always @(posedge clk) begin
        if (!rst && s_valid) input_pixel_count <= input_pixel_count + 1;
    end

    // ---- probe: log every swap pulse from control.v ----
    always @(posedge clk) begin
        if (!rst && dut.u_control.swap && swap_event_count < 16) begin
            swap_at_input_raster[swap_event_count] <= input_pixel_count;
            swap_at_out_ptr[swap_event_count]      <= out_ptr;
            swap_event_count                       <= swap_event_count + 1;
        end
    end

    // ---- probe: log every change to live taps in tap_reg_file ----
    // Use tap0 and tap11 together as a fingerprint (they always change together
    // on swap, so watching them detects any live-tap update).
    always @(posedge clk) begin
        if (!rst) begin
            if ((dut.u_tap_reg.taps_live_r[0]  !== prev_live_tap0) ||
                (dut.u_tap_reg.taps_live_r[11] !== prev_live_tap11)) begin
                if (live_change_count < 16) begin
                    live_change_at_k[live_change_count] <= out_ptr;
                    live_change_count <= live_change_count + 1;
                end
                prev_live_tap0  <= dut.u_tap_reg.taps_live_r[0];
                prev_live_tap11 <= dut.u_tap_reg.taps_live_r[11];
            end
        end
    end

    initial begin
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_multi_ru_input.hex",    input_img);
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_multi_ru_expected.hex", expected_img);
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_multi_ru_taps.hex",     tap_stream);

        out_ptr    = 0;
        err_count  = 0;

        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // Preload RU(0,0) into shadow. SOF's ru_changed will (SWAP_DELAY cycles
        // later, ~pixel 1542) trigger swap[0] -> live = RU(0,0).
        write_ru_taps(0);

        // ---- stream pixels; continuously alternate shadow loads ----
        // Every 256 input cycles, control.v fires ru_changed (either mid-row at
        // col 256, or row-wrap at col 0). Delayed swap fires SWAP_DELAY=3*W+6
        // cycles later. Shadow must hold the correct next-RU value when each
        // swap fires. Load window for interval N: starts at pixel LOAD_START+N*256
        // (13 cycles: 12 taps + 1 norm write). Target for swap[N+1] = (N+1)%2.
        //
        //   LOAD_START chosen > SWAP_DELAY(=1542 for W=512) so preloaded shadow
        //   survives until swap[0] fires. Give margin: 1550.
        begin : stream
            integer rel_i, phase, step, target_ru;
            for (i = 0; i < H*W; i = i + 1) begin
                @(posedge clk);
                s_valid <= 1'b1;
                s_sof   <= (i == 0);
                s_pixel <= input_img[i];

                rel_i = i - 1550;
                if (rel_i >= 0 && (rel_i % 256) < 13) begin
                    phase     = rel_i / 256;
                    step      = rel_i % 256;
                    target_ru = (phase + 1) % 2;
                    wr_en <= 1'b1;
                    if (step < 12) begin
                        wr_addr <= step[5:0];
                        wr_data <= {25'b0, tap_stream[target_ru*14 + step][6:0]};
                    end else begin
                        wr_addr <= 6'd12;
                        wr_data <= {16'b0, tap_stream[target_ru*14 + 12], tap_stream[target_ru*14 + 13]};
                    end
                end else begin
                    wr_en <= 1'b0;
                end
            end
        end
        @(posedge clk);
        s_valid <= 1'b0;
        s_sof   <= 1'b0;

        // drain
        repeat (4000) @(posedge clk);

        // ---- self-calibrating compare ----
        // captured[k] corresponds to window centered on some output pixel; the
        // exact k->(out_r,out_c) mapping depends on total pipeline latency.
        // Assume first_valid corresponds to input pixel at raster (base_raster + k),
        // where base_raster = 6*W + BASE_OFFSET. Sweep BASE_OFFSET, pick best.
        begin : calibrate
            integer off, best_off, best_err;
            integer k, in_raster, in_r, in_c, out_r, out_c, checked, mm;
            integer colhist [0:511];
            integer ci;
            for (ci = 0; ci < 512; ci = ci + 1) colhist[ci] = 0;
            best_err = 32'h7fffffff;
            best_off = 0;
            for (off = 0; off <= 30; off = off + 1) begin
                mm = 0; checked = 0;
                for (k = 0; k < out_ptr; k = k + 1) begin
                    in_raster = 6*W + off + k;
                    in_r      = in_raster / W;
                    in_c      = in_raster % W;
                    out_r     = in_r - 3;
                    out_c     = in_c - 3;
                    if (out_r >= 3 && out_r <= H-4 && out_c >= 3 && out_c <= W-4) begin
                        checked = checked + 1;
                        if (captured_img[k] !== expected_img[out_r*W + out_c])
                            mm = mm + 1;
                    end
                end
                $display("offset=%2d checked=%0d mismatches=%0d", off, checked, mm);
                if (mm < best_err) begin
                    best_err = mm;
                    best_off = off;
                end
            end
            $display("---- best offset = %0d with %0d mismatches ----", best_off, best_err);

            // Re-run at best offset, print first 40 mismatches with their positions
            for (k = 0; k < out_ptr; k = k + 1) begin
                in_raster = 6*W + best_off + k;
                in_r      = in_raster / W;
                in_c      = in_raster % W;
                out_r     = in_r - 3;
                out_c     = in_c - 3;
                if (out_r >= 3 && out_r <= H-4 && out_c >= 3 && out_c <= W-4) begin
                    if (captured_img[k] !== expected_img[out_r*W + out_c]) begin
                        if (err_count < 40)
                            $display("MISMATCH k=%0d -> out(%0d,%0d) RU=%0d  got=%02x exp=%02x",
                                     k, out_r, out_c, out_r/RU_SIZE,
                                     captured_img[k], expected_img[out_r*W + out_c]);
                        err_count = err_count + 1;
                        colhist[out_c] = colhist[out_c] + 1;
                    end
                end
            end
            $display("---- mismatch histogram by out_c (nonzero bins only) ----");
            for (ci = 0; ci < 512; ci = ci + 1) begin
                if (colhist[ci] > 0)
                    $display("  out_c=%0d : %0d mismatches", ci, colhist[ci]);
            end
        end
        if (err_count == 0)
            $display("PASS: all interior pixels match at best offset");
        else
            $display("FAIL: %0d interior mismatches at best offset", err_count);

        // ---- probe report ----
        $display("---- probe: swap events ----");
        $display("swap fired %0d times", swap_event_count);
        for (i = 0; i < swap_event_count; i = i + 1) begin
            $display("  swap[%0d]: input pixel #%0d (row %0d col %0d), out_ptr=%0d at that moment",
                     i,
                     swap_at_input_raster[i],
                     swap_at_input_raster[i] / W,
                     swap_at_input_raster[i] % W,
                     swap_at_out_ptr[i]);
        end
        $display("---- probe: live_taps changes ----");
        $display("live_taps changed %0d times", live_change_count);
        for (i = 0; i < live_change_count; i = i + 1) begin
            $display("  live[%0d]: at out_ptr=%0d  -> first output pixel that used the NEW taps is captured[%0d]",
                     i,
                     live_change_at_k[i],
                     live_change_at_k[i]);
        end
        $finish;
    end

endmodule