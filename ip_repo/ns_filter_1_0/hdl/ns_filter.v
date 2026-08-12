`timescale 1 ns / 1 ps

// -----------------------------------------------------------------------------
// ns_filter.v — top-level IP wrapper (edited from Vivado wizard-generated
// version). Presents:
//   - AXI-Lite slave        (taps, norm, frame dims, start)
//   - AXI-Stream slave      (pixels in from MM2S DMA)
//   - AXI-Stream master     (pixels out + TLAST to S2MM DMA)
//
// What this wrapper adds beyond the original wizard skeleton:
//   1. Frame-dimension + start control registers decoded at word indices 13-15
//      (byte offsets 0x34, 0x38, 0x3C). Wizard AXI-Lite slave is UNCHANGED —
//      it already pulses reg_wr_en/reg_wr_addr/reg_wr_data for every write;
//      tap_reg_file inside ns_filter_top ignores addr >=13, we consume them.
//   2. Auto SOF pulse on first accepted input pixel after reset or start.
//   3. Small output FIFO (depth 32) so brief S2MM stalls don't lose pixels
//      (ns_filter_top's pipeline has no enable and can't stall mid-flow).
//   4. Backpressure on s00_axis_tready when FIFO is near-full.
//   5. TLAST assertion on the (frame_height-6)*frame_width-th output beat
//      (matches actual pixel count ns_filter_top emits: line-buffer fill
//      consumes the first 6 rows; PS handles remaining borders in software).
//
// SINGLE-CLOCK ASSUMPTION: s00_axi_aclk, s00_axis_aclk, m00_axis_aclk are
// tied to the same source in the surrounding block design (standard for
// PYNQ). If ever run truly multi-clock, everything crossing between them
// needs proper CDC — not present here.
//
// Register map (byte offsets — same 6-bit / 64-byte space as the wizard IP):
//   WRITES (host -> IP):
//     0x00..0x2C : taps[0..11]  (12 x 7-bit tap, low bits of each 32-bit word)
//     0x30       : norm         (Q0.16, low 16 bits)
//     0x34       : frame_width  (low 16 bits — MUST match FRAME_W parameter)
//     0x38       : frame_height (low 16 bits — runtime frame row count)
//     0x3C       : control      (bit 0 = start-of-frame pulse; PS writes 1
//                                before each frame to arm SOF + reset TLAST
//                                counter with the current frame dimensions)
//                                (bit 1 = flip_bank pulse: atomically swap
//                                active/inactive coefficient-bank roles;
//                                only issue between frames, never mid-stream)
//                                (bits [13:8] = wr_bank_idx: persistent
//                                index into inactive bank for subsequent
//                                tap/norm writes at 0x00..0x30)
//
//   READS (IP -> host) — debug/status, ALIASED onto low offsets. Since AXI-Lite
//   reads and writes are independent transactions, reading these addresses
//   returns status data (not what was written to the same address):
//     0x00 : pixel_count  (32-bit) accepted output beats since last start
//     0x04 : flags: [3]=tlast_fired [2]=fifo_overflow [1]=sof_seen [0]=start_ack
//                    Sticky since last start_pulse (except start_ack sticky since reset).
//     0x08 : {16'b0, frame_w_r} — readback of last frame_width write
//     0x0C : {16'b0, frame_h_r} — readback of last frame_height write
//     0x10 : {27'b0, fifo_count[4:0]} — current output-FIFO fill
//     other : 0xDEAD_BEEF (unmapped)
// -----------------------------------------------------------------------------

module ns_filter #
(
    parameter integer C_S00_AXI_DATA_WIDTH    = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH    = 6,

    parameter integer C_S00_AXIS_TDATA_WIDTH  = 32,
    parameter integer C_M00_AXIS_TDATA_WIDTH  = 32,
    parameter integer C_M00_AXIS_START_COUNT  = 32,  // unused; kept for wizard XML

    parameter integer FRAME_W                 = 1920,
    parameter integer RU_SHIFT                = 8,
    parameter integer OUT_FIFO_LOG2_DEPTH     = 5     // 32-entry output FIFO
)
(
    // ---- AXI-Lite slave ----
    input  wire s00_axi_aclk,
    input  wire s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input  wire [2 : 0] s00_axi_awprot,
    input  wire  s00_axi_awvalid,
    output wire  s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input  wire  s00_axi_wvalid,
    output wire  s00_axi_wready,
    output wire [1 : 0] s00_axi_bresp,
    output wire  s00_axi_bvalid,
    input  wire  s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input  wire [2 : 0] s00_axi_arprot,
    input  wire  s00_axi_arvalid,
    output wire  s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [1 : 0] s00_axi_rresp,
    output wire  s00_axi_rvalid,
    input  wire  s00_axi_rready,

    // ---- AXI-Stream pixel in ----
    input  wire s00_axis_aclk,
    input  wire s00_axis_aresetn,
    output wire s00_axis_tready,
    input  wire [C_S00_AXIS_TDATA_WIDTH-1 : 0] s00_axis_tdata,
    input  wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
    input  wire s00_axis_tlast,
    input  wire s00_axis_tvalid,

    // ---- AXI-Stream pixel out ----
    input  wire m00_axis_aclk,
    input  wire m00_axis_aresetn,
    output wire m00_axis_tvalid,
    output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0] m00_axis_tdata,
    output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
    output wire m00_axis_tlast,
    input  wire m00_axis_tready
);

    // Single-clock assumption (see header comment)
    wire clk   = s00_axi_aclk;
    wire rst_i = ~s00_axi_aresetn;

    // Register-write pulse from AXI-Lite slave
    wire        reg_wr_en;
    wire  [5:0] reg_wr_addr;
    wire [31:0] reg_wr_data;

    // Read-side signals (status regs muxed below)
    wire  [5:0] reg_rd_addr;
    reg  [31:0] reg_rd_data;

    // =========================================================================
    // AXI-Lite slave
    // =========================================================================
    ns_filter_slave_lite_v1_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
    ) u_axi_lite (
        .reg_wr_en   (reg_wr_en),
        .reg_wr_addr (reg_wr_addr),
        .reg_wr_data (reg_wr_data),
        .reg_rd_addr (reg_rd_addr),
        .reg_rd_data (reg_rd_data),
        .S_AXI_ACLK    (s00_axi_aclk),
        .S_AXI_ARESETN (s00_axi_aresetn),
        .S_AXI_AWADDR  (s00_axi_awaddr),
        .S_AXI_AWPROT  (s00_axi_awprot),
        .S_AXI_AWVALID (s00_axi_awvalid),
        .S_AXI_AWREADY (s00_axi_awready),
        .S_AXI_WDATA   (s00_axi_wdata),
        .S_AXI_WSTRB   (s00_axi_wstrb),
        .S_AXI_WVALID  (s00_axi_wvalid),
        .S_AXI_WREADY  (s00_axi_wready),
        .S_AXI_BRESP   (s00_axi_bresp),
        .S_AXI_BVALID  (s00_axi_bvalid),
        .S_AXI_BREADY  (s00_axi_bready),
        .S_AXI_ARADDR  (s00_axi_araddr),
        .S_AXI_ARPROT  (s00_axi_arprot),
        .S_AXI_ARVALID (s00_axi_arvalid),
        .S_AXI_ARREADY (s00_axi_arready),
        .S_AXI_RDATA   (s00_axi_rdata),
        .S_AXI_RRESP   (s00_axi_rresp),
        .S_AXI_RVALID  (s00_axi_rvalid),
        .S_AXI_RREADY  (s00_axi_rready)
    );

    // =========================================================================
    // Control regs: frame dimensions + start pulse (word indices 13/14/15)
    // =========================================================================
    reg [15:0] frame_w_r;
    reg [15:0] frame_h_r;
    reg        start_pulse_r;
    reg        flip_bank_r;      // 1-cycle pulse to tap_reg_file
    reg  [5:0] wr_bank_idx_r;    // persistent — routes tap writes into inactive bank

    always @(posedge clk) begin
        if (rst_i) begin
            frame_w_r     <= 16'd0;
            frame_h_r     <= 16'd0;
            start_pulse_r <= 1'b0;
            flip_bank_r   <= 1'b0;
            wr_bank_idx_r <= 6'd0;
        end else begin
            start_pulse_r <= 1'b0;   // default: single-cycle pulse
            flip_bank_r   <= 1'b0;   // default: single-cycle pulse
            if (reg_wr_en) begin
                case (reg_wr_addr)
                    6'd13: frame_w_r <= reg_wr_data[15:0];
                    6'd14: frame_h_r <= reg_wr_data[15:0];
                    6'd15: begin
                        start_pulse_r <= reg_wr_data[0];
                        flip_bank_r   <= reg_wr_data[1];
                        wr_bank_idx_r <= reg_wr_data[13:8];
                    end
                    default: ;   // taps + norm handled inside tap_reg_file
                endcase
            end
        end
    end

    // =========================================================================
    // SOF generator: first accepted input pixel after reset or start_pulse
    // =========================================================================
    reg sof_pending;
    wire s_axis_handshake = s00_axis_tvalid && s00_axis_tready;

    always @(posedge clk) begin
        if (rst_i)                                    sof_pending <= 1'b1;
        else if (start_pulse_r)                       sof_pending <= 1'b1;
        else if (s_axis_handshake && sof_pending)     sof_pending <= 1'b0;
    end
    wire s_sof_pulse = sof_pending && s_axis_handshake;

    // =========================================================================
    // Output FIFO declarations (moved above flush block so fifo_needs_bp is
    // visible where the flush counter references it — declaration-before-use).
    // =========================================================================
    localparam integer OUT_FIFO_DEPTH  = 1 << OUT_FIFO_LOG2_DEPTH;
    localparam integer OUT_FIFO_MARGIN = 12;   // > longest in-flight pipeline

    reg  [7:0]                     fifo_mem [0:OUT_FIFO_DEPTH-1];
    reg  [OUT_FIFO_LOG2_DEPTH:0]   fifo_wptr;
    reg  [OUT_FIFO_LOG2_DEPTH:0]   fifo_rptr;

    wire [OUT_FIFO_LOG2_DEPTH:0]   fifo_count   = fifo_wptr - fifo_rptr;
    wire                           fifo_empty   = (fifo_wptr == fifo_rptr);
    wire                           fifo_needs_bp= (fifo_count >=
                                       (OUT_FIFO_DEPTH[OUT_FIFO_LOG2_DEPTH:0]
                                        - OUT_FIFO_MARGIN[OUT_FIFO_LOG2_DEPTH:0]));

    wire        nsft_m_valid;
    wire  [7:0] nsft_m_pixel;

    // =========================================================================
    // Pipeline tail flush.
    // ns_filter_top's internal pipeline advances only on s_valid=1. After MM2S
    // ends and s_axis_handshake stops, the last ~6 in-flight outputs would be
    // stuck. We generate synthetic s_valid pulses after the last real input so
    // the tail drains and TLAST fires on the correct beat. FLUSH_CYCLES > true
    // pipeline latency (6); the extra pulses cause a few garbage outputs after
    // TLAST that are discarded by the FIFO reset on the next start_pulse.
    // =========================================================================
    localparam integer FLUSH_CYCLES = 12;

    reg [31:0] input_count;
    reg [31:0] input_target;
    reg  [3:0] flush_count;
    wire       flush_active = (flush_count != 4'd0);

    always @(posedge clk) begin
        if (rst_i) begin
            input_count  <= 32'd0;
            input_target <= 32'd0;
            flush_count  <= 4'd0;
        end else if (start_pulse_r) begin
            input_count  <= 32'd0;
            input_target <= frame_w_r * frame_h_r;
            flush_count  <= 4'd0;
        end else begin
            if (s_axis_handshake) begin
                input_count <= input_count + 32'd1;
                if (input_count + 32'd1 == input_target)
                    flush_count <= FLUSH_CYCLES[3:0];
            end else if (flush_active && !fifo_needs_bp) begin
                flush_count <= flush_count - 4'd1;
            end
        end
    end

    // FIFO pointers reset on start_pulse too, so garbage from post-TLAST
    // flush pulses of the previous frame doesn't leak into the next frame.
    always @(posedge clk) begin
        if (rst_i || start_pulse_r) begin
            fifo_wptr <= 0;
        end else if (nsft_m_valid) begin
            fifo_mem[fifo_wptr[OUT_FIFO_LOG2_DEPTH-1:0]] <= nsft_m_pixel;
            fifo_wptr <= fifo_wptr + 1'b1;
        end
    end

    wire fifo_read = m00_axis_tvalid && m00_axis_tready;
    always @(posedge clk) begin
        if (rst_i || start_pulse_r) fifo_rptr <= 0;
        else if (fifo_read)         fifo_rptr <= fifo_rptr + 1'b1;
    end

    // Drive master AXI-Stream port from FIFO. TDATA is 32-bit; pixel in low byte.
    assign m00_axis_tdata  = {{(C_M00_AXIS_TDATA_WIDTH-8){1'b0}},
                              fifo_mem[fifo_rptr[OUT_FIFO_LOG2_DEPTH-1:0]]};
    assign m00_axis_tvalid = !fifo_empty;
    assign m00_axis_tstrb  = {(C_M00_AXIS_TDATA_WIDTH/8){1'b1}};

    // Backpressure upstream when FIFO is near-full
    assign s00_axis_tready = !fifo_needs_bp;

    // =========================================================================
    // TLAST counter: fires on (frame_height - 6) * frame_width-th accepted beat
    // =========================================================================
    reg [31:0] pixel_count;
    reg [31:0] pixels_per_frame;
    wire       last_beat = (pixel_count + 32'd1 == pixels_per_frame);

    always @(posedge clk) begin
        if (rst_i) begin
            pixel_count      <= 32'd0;
            pixels_per_frame <= 32'd0;
        end else if (start_pulse_r) begin
            pixel_count      <= 32'd0;
            pixels_per_frame <= (frame_h_r - 16'd6) * frame_w_r;
        end else if (fifo_read) begin
            pixel_count <= pixel_count + 32'd1;
        end
    end
    assign m00_axis_tlast = m00_axis_tvalid && m00_axis_tready && last_beat;

    // =========================================================================
    // Status flags (sticky since last start; readable at 0x48)
    // =========================================================================
    wire fifo_full         = (fifo_count == OUT_FIFO_DEPTH[OUT_FIFO_LOG2_DEPTH:0]);
    wire fifo_overflow_now = nsft_m_valid && fifo_full;   // pixel would be dropped

    reg start_ack_r;      // set on any start pulse since reset
    reg sof_seen_r;       // set on SOF, cleared on start
    reg fifo_overflow_r;  // set on overflow, cleared on start
    reg tlast_fired_r;    // set on m00_axis_tlast, cleared on start

    always @(posedge clk) begin
        if (rst_i) begin
            start_ack_r     <= 1'b0;
            sof_seen_r      <= 1'b0;
            fifo_overflow_r <= 1'b0;
            tlast_fired_r   <= 1'b0;
        end else begin
            if (start_pulse_r) begin
                start_ack_r     <= 1'b1;
                sof_seen_r      <= 1'b0;
                fifo_overflow_r <= 1'b0;
                tlast_fired_r   <= 1'b0;
            end
            if (s_sof_pulse)       sof_seen_r      <= 1'b1;
            if (fifo_overflow_now) fifo_overflow_r <= 1'b1;
            if (m00_axis_tlast)    tlast_fired_r   <= 1'b1;
        end
    end

    // =========================================================================
    // Read-data mux — combinational; slave latches into RDATA
    // =========================================================================
    always @(*) begin
        case (reg_rd_addr)
            6'd0:    reg_rd_data = pixel_count;
            6'd1:    reg_rd_data = {28'b0, tlast_fired_r, fifo_overflow_r,
                                          sof_seen_r,    start_ack_r};
            6'd2:    reg_rd_data = {16'b0, frame_w_r};
            6'd3:    reg_rd_data = {16'b0, frame_h_r};
            6'd4:    reg_rd_data = {{(32-(OUT_FIFO_LOG2_DEPTH+1)){1'b0}}, fifo_count};
            default: reg_rd_data = 32'hDEAD_BEEF;
        endcase
    end

    // =========================================================================
    // ns_filter_top instance (UNCHANGED — same verified core)
    // =========================================================================
    // s_valid to filter: real handshake OR internal flush pulse. Flush stalls
    // if FIFO is near-full (respects backpressure just like real handshakes).
    wire       s_valid_to_filter = s_axis_handshake ||
                                   (flush_active && !fifo_needs_bp);
    wire [7:0] s_pixel_to_filter = s_axis_handshake ? s00_axis_tdata[7:0] : 8'd0;

    ns_filter_top #(
        .FRAME_W (FRAME_W),
        .LINE_W  (FRAME_W),
        .RU_SHIFT(RU_SHIFT)
    ) u_ns_filter_top (
        .clk        (clk),
        .rst        (rst_i),
        .start_pulse(start_pulse_r),   // clears per-frame carryover in
                                        // line_buffer/window_former/control
                                        // (not tap_reg_file — banks persist)
        .s_valid    (s_valid_to_filter),
        .s_sof      (s_sof_pulse),
        .s_pixel    (s_pixel_to_filter),
        .m_valid    (nsft_m_valid),
        .m_pixel    (nsft_m_pixel),
        .wr_en      (reg_wr_en),
        .wr_addr    (reg_wr_addr),
        .wr_data    (reg_wr_data),
        .wr_bank_idx(wr_bank_idx_r),
        .flip_bank  (flip_bank_r)
    );

endmodule
