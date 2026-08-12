`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 22:57:52
// Design Name: 
// Module Name: tb_ns_filter_top
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

`timescale 1ns/1ps

module tb_ns_filter_top;
    // Tiny frame so simulation runs fast: 8 cols wide, 8 rows tall, 2x2 RUs
    localparam FRAME_W  = 8;
    localparam LINE_W   = 8;
    localparam RU_SHIFT = 1;
    localparam N_ROWS   = 8;

    reg          clk = 0;
    reg          rst = 1;
    reg          s_valid = 0;
    reg          s_sof = 0;
    reg   [7:0]  s_pixel = 0;
    wire         m_valid;
    wire  [7:0]  m_pixel;
    reg          wr_en = 0;
    reg   [5:0]  wr_addr = 0;
    reg  [31:0]  wr_data = 0;

    integer errors = 0;
    integer i, r, c;
    integer m_valid_count;
    integer m_first_valid_cyc;
    integer input_cyc;
    reg  [31:0] wtmp;

    always #5 clk = ~clk;

    ns_filter_top #(
        .FRAME_W(FRAME_W), .LINE_W(LINE_W), .RU_SHIFT(RU_SHIFT)
    ) dut (
        .clk(clk), .rst(rst),
        .s_valid(s_valid), .s_sof(s_sof), .s_pixel(s_pixel),
        .m_valid(m_valid), .m_pixel(m_pixel),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data)
    );

    task write_reg(input [5:0] addr, input [31:0] data);
        begin
            wr_addr = addr;
            wr_data = data;
            wr_en   = 1'b1;
            @(posedge clk); #1;
            wr_en   = 1'b0;
        end
    endtask

    // Latch first cycle m_valid rises (relative to input start)
    reg m_valid_seen = 0;
    always @(posedge clk) begin
        if (!m_valid_seen && m_valid) begin
            m_valid_seen      <= 1'b1;
            m_first_valid_cyc <= input_cyc;
        end
    end

    initial begin
        input_cyc         = 0;
        m_first_valid_cyc = 0;
        m_valid_count     = 0;

        repeat (4) @(posedge clk);
        #1 rst = 0;

        // --- Test 1: all-zero tap set -> output must be all zeros ---
        for (i = 0; i < 12; i = i + 1) write_reg(i[5:0], 32'd0);
        write_reg(6'd12, 32'h0000_8000);           // arbitrary non-zero norm

        // Feed one full 8x8 frame in raster order.
        s_valid = 1;
        s_sof   = 1;
        for (r = 0; r < N_ROWS; r = r + 1) begin
            for (c = 0; c < FRAME_W; c = c + 1) begin
                s_pixel = (r << 4) | c[3:0];       // distinct 0x00..0x77
                @(posedge clk); #1;
                s_sof         = 0;
                input_cyc     = input_cyc + 1;
                if (m_valid) begin
                    m_valid_count = m_valid_count + 1;
                    if (m_pixel !== 8'd0) begin
                        $display("FAIL zero-tap: cyc=%0d m_pixel=%h",
                                 input_cyc, m_pixel);
                        errors = errors + 1;
                    end
                end
            end
        end
        s_valid = 0;

        // Drain the pipeline for a while
        repeat (16) @(posedge clk);

        $display("Test 1 (zero taps):   inputs=%0d, valid outs=%0d, first at cyc=%0d",
                 N_ROWS*FRAME_W, m_valid_count, m_first_valid_cyc);

        // Fill latency should be roughly 6*LINE_W + a few pipeline stages.
        if (m_first_valid_cyc < 6*LINE_W) begin
            $display("FAIL: m_valid asserted too early (cyc=%0d, expected >= %0d)",
                     m_first_valid_cyc, 6*LINE_W);
            errors = errors + 1;
        end
        if (m_valid_count == 0) begin
            $display("FAIL: no valid outputs produced");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: integration sanity");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule