`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// tb_ns_filter_axi.v
//
// Lightweight testbench for the ns_filter IP wrapper (ns_filter.v). Verifies
// ONLY the wrapper-level logic that was added in this session:
//   1. AXI-Lite writes reach the internal control regs (probe frame_w_r,
//      frame_h_r inside dut).
//   2. TLAST fires on exactly the (H-6)*W-th accepted output beat.
//   3. Backpressure works: stalling m_axis_tready causes the output FIFO to
//      fill and s_axis_tready to drop before overflow; releasing recovers.
//
// The ns_filter_top core is already exhaustively verified by tb_multi_ru_*,
// so this TB does NOT compare pixel output against a golden model — that's
// out of scope for wrapper verification.
//
// Small frame (H=32, W=64) to keep sim fast: 2048 input beats, 1664 output.
// -----------------------------------------------------------------------------

module tb_ns_filter_axi;

    localparam integer H            = 32;
    localparam integer W            = 64;
    localparam integer EXPECTED_OUT = (H - 6) * W;   // 26 * 64 = 1664

    // ------------------------------------------------------------ Clock/reset
    reg clk = 0;  always #3.333 clk = ~clk;   // ~150 MHz
    reg aresetn = 0;

    // ------------------------------------------------------------ AXI-Lite
    reg  [5:0]  awaddr;
    reg         awvalid = 0;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid = 0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready = 0;
    reg  [5:0]  araddr = 0;
    reg  [2:0]  arprot = 0;
    reg         arvalid = 0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready = 0;

    // ------------------------------------------------------------ AXI-Stream in
    reg  [31:0] s_axis_tdata    = 0;
    reg  [3:0]  s_axis_tstrb    = 4'hF;
    reg         s_axis_tlast_in = 0;
    reg         s_axis_tvalid   = 0;
    wire        s_axis_tready;

    // ------------------------------------------------------------ AXI-Stream out
    wire        m_axis_tvalid;
    wire [31:0] m_axis_tdata;
    wire [3:0]  m_axis_tstrb;
    wire        m_axis_tlast;
    reg         m_axis_tready = 1;

    // ------------------------------------------------------------ DUT
    ns_filter #(
        .FRAME_W            (W),
        .RU_SHIFT           (8),
        .OUT_FIFO_LOG2_DEPTH(5)
    ) dut (
        .s00_axi_aclk    (clk),
        .s00_axi_aresetn (aresetn),
        .s00_axi_awaddr  (awaddr),
        .s00_axi_awprot  (3'b000),
        .s00_axi_awvalid (awvalid),
        .s00_axi_awready (awready),
        .s00_axi_wdata   (wdata),
        .s00_axi_wstrb   (wstrb),
        .s00_axi_wvalid  (wvalid),
        .s00_axi_wready  (wready),
        .s00_axi_bresp   (bresp),
        .s00_axi_bvalid  (bvalid),
        .s00_axi_bready  (bready),
        .s00_axi_araddr  (araddr),
        .s00_axi_arprot  (arprot),
        .s00_axi_arvalid (arvalid),
        .s00_axi_arready (arready),
        .s00_axi_rdata   (rdata),
        .s00_axi_rresp   (rresp),
        .s00_axi_rvalid  (rvalid),
        .s00_axi_rready  (rready),

        .s00_axis_aclk    (clk),
        .s00_axis_aresetn (aresetn),
        .s00_axis_tready  (s_axis_tready),
        .s00_axis_tdata   (s_axis_tdata),
        .s00_axis_tstrb   (s_axis_tstrb),
        .s00_axis_tlast   (s_axis_tlast_in),
        .s00_axis_tvalid  (s_axis_tvalid),

        .m00_axis_aclk    (clk),
        .m00_axis_aresetn (aresetn),
        .m00_axis_tvalid  (m_axis_tvalid),
        .m00_axis_tdata   (m_axis_tdata),
        .m00_axis_tstrb   (m_axis_tstrb),
        .m00_axis_tlast   (m_axis_tlast),
        .m00_axis_tready  (m_axis_tready)
    );

    // ------------------------------------------------------------ AXI-Lite write task
    task axi_write(input [5:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            bready  <= 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            while (!bvalid) @(posedge clk);
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------ Probes
    integer out_count         = 0;
    integer tlast_fired_at    = -1;
    integer tready_dropped_at = -1;
    integer errors            = 0;
    reg     last_tready       = 1'b1;

    always @(posedge clk) begin
        if (aresetn) begin
            if (m_axis_tvalid && m_axis_tready) begin
                out_count <= out_count + 1;
                if (m_axis_tlast && tlast_fired_at < 0)
                    tlast_fired_at <= out_count + 1;
            end
            if (!s_axis_tready && last_tready && tready_dropped_at < 0)
                tready_dropped_at <= out_count;
            last_tready <= s_axis_tready;
        end
    end

    // ------------------------------------------------------------ Helper: load taps
    integer j;
    task load_taps_and_dims;
        begin
            // Sharpener: taps 0-10 = -2 (7-bit = 0x7E), tap 11 = 50 (0x32).
            // Norm = round(2^16 / dc_gain) where dc_gain = 2*(-22)+50 = 6 -> 10923 = 0x2AAB
            for (j = 0; j < 11; j = j + 1)
                axi_write(6'd0 + j[5:0], 32'h0000007E);
            axi_write(6'd11, 32'h00000032);
            axi_write(6'd12, 32'h00002AAB);
            axi_write(6'd13, W);
            axi_write(6'd14, H);
        end
    endtask

    // ------------------------------------------------------------ Main test
    integer i;
    initial begin
        $display("=== ns_filter wrapper testbench ===");
        $display("Frame: H=%0d W=%0d, expected output beats = %0d", H, W, EXPECTED_OUT);

        repeat (10) @(posedge clk);
        aresetn <= 1;
        repeat (5) @(posedge clk);

        // ---------------- Test 1: AXI-Lite writes reach control regs ----------
        $display("");
        $display("--- Test 1: AXI-Lite config writes ---");
        load_taps_and_dims();

        if (dut.frame_w_r !== W[15:0]) begin
            $display("FAIL: dut.frame_w_r = %0d, expected %0d", dut.frame_w_r, W);
            errors = errors + 1;
        end else begin
            $display("  OK: dut.frame_w_r = %0d", dut.frame_w_r);
        end
        if (dut.frame_h_r !== H[15:0]) begin
            $display("FAIL: dut.frame_h_r = %0d, expected %0d", dut.frame_h_r, H);
            errors = errors + 1;
        end else begin
            $display("  OK: dut.frame_h_r = %0d", dut.frame_h_r);
        end

        // Start pulse
        axi_write(6'd15, 32'h1);

        // ---------------- Test 2: TLAST fires on correct beat ---------------
        $display("");
        $display("--- Test 2: TLAST timing ---");
        m_axis_tready <= 1;
        repeat (2) @(posedge clk);

        for (i = 0; i < H*W; i = i + 1) begin
            @(posedge clk);
            s_axis_tvalid <= 1'b1;
            s_axis_tdata  <= {24'b0, i[7:0]};
            while (!s_axis_tready) @(posedge clk);
        end
        @(posedge clk);
        s_axis_tvalid <= 1'b0;

        // Wait for TLAST or timeout
        i = 0;
        while (tlast_fired_at < 0 && i < 20000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (20) @(posedge clk);

        $display("  Total output beats: %0d", out_count);
        $display("  TLAST fired at beat #%0d (expected #%0d)", tlast_fired_at, EXPECTED_OUT);
        if (tlast_fired_at != EXPECTED_OUT) begin
            $display("FAIL: TLAST fired at wrong beat");
            errors = errors + 1;
        end else begin
            $display("  OK: TLAST fired on the correct beat");
        end

        // ---------------- Test 3: Backpressure ---------------
        $display("");
        $display("--- Test 3: Backpressure ---");
        aresetn <= 0;
        repeat (10) @(posedge clk);
        aresetn <= 1;
        // Reset probe state manually
        out_count         = 0;
        tlast_fired_at    = -1;
        tready_dropped_at = -1;
        last_tready       = 1'b1;
        repeat (5) @(posedge clk);

        load_taps_and_dims();
        axi_write(6'd15, 32'h1);
        m_axis_tready <= 1;
        repeat (2) @(posedge clk);

        // Stream + mid-frame master stall
        fork
            begin : streamer
                for (i = 0; i < H*W; i = i + 1) begin
                    @(posedge clk);
                    s_axis_tvalid <= 1'b1;
                    s_axis_tdata  <= {24'b0, i[7:0]};
                    while (!s_axis_tready) @(posedge clk);
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b0;
            end
            begin : stall_master
                while (out_count < 100) @(posedge clk);
                $display("  Stalling m_axis_tready for 200 cycles at out_count=%0d", out_count);
                m_axis_tready <= 1'b0;
                repeat (200) @(posedge clk);
                m_axis_tready <= 1'b1;
                $display("  m_axis_tready released at out_count=%0d", out_count);
            end
        join

        i = 0;
        while (tlast_fired_at < 0 && i < 20000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (20) @(posedge clk);

        if (tready_dropped_at < 0) begin
            $display("FAIL: s_axis_tready never dropped during m_axis_tready stall");
            errors = errors + 1;
        end else begin
            $display("  OK: s_axis_tready dropped at out_count=%0d during stall", tready_dropped_at);
        end
        $display("  After stall/release: total output beats = %0d, TLAST at #%0d",
                 out_count, tlast_fired_at);
        if (tlast_fired_at != EXPECTED_OUT) begin
            $display("FAIL: post-backpressure TLAST at wrong beat (got %0d, expected %0d)",
                     tlast_fired_at, EXPECTED_OUT);
            errors = errors + 1;
        end else begin
            $display("  OK: TLAST still fires correctly after backpressure recovery");
        end

        // ---------------- Summary ---------------
        $display("");
        if (errors == 0)
            $display("=== PASS: all wrapper checks OK ===");
        else
            $display("=== FAIL: %0d error(s) ===", errors);
        $finish;
    end

endmodule
