`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 23:17:35
// Design Name: 
// Module Name: tb_ns_verify
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

module tb_ns_verify;
    localparam FRAME_W  = 8;
    localparam LINE_W   = 8;
    localparam N_ROWS   = 12;
    localparam N_PIX    = FRAME_W * N_ROWS;
    localparam RU_SHIFT = 3;                   // whole frame is one RU

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
    integer i;

    reg  [7:0]  input_mem   [0:N_PIX-1];
    reg  [7:0]  tap_mem     [0:11];
    reg [15:0]  norm_mem    [0:0];
    reg  [7:0]  expected_mem[0:N_PIX-1];

    reg  [7:0]  captured    [0:N_PIX-1];
    integer     n_captured = 0;

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
            wr_addr = addr; wr_data = data; wr_en = 1'b1;
            @(posedge clk); #1;
            wr_en = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (m_valid && n_captured < N_PIX) begin
            captured[n_captured] <= m_pixel;
            n_captured           <= n_captured + 1;
        end
    end

    initial begin
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_input.hex",    input_mem);
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_taps.hex",     tap_mem);
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_norm.hex",     norm_mem);
        $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_ns/ns_expected.hex", expected_mem);

        repeat (4) @(posedge clk);
        #1 rst = 0;

        // Load taps + norm into shadow via AXI-Lite writes
        for (i = 0; i < 12; i = i + 1)
            write_reg(i[5:0], {24'd0, tap_mem[i]});
        write_reg(6'd12, {16'd0, norm_mem[0]});

        // Feed the image; SOF fires a swap so live<-shadow before pixels arrive
        // at the multipliers.
        s_valid = 1'b1;
        s_sof   = 1'b1;
        for (i = 0; i < N_PIX; i = i + 1) begin
            s_pixel = input_mem[i];
            @(posedge clk); #1;
            s_sof   = 1'b0;
        end
        s_valid = 1'b0;

        // Drain
        repeat (32) @(posedge clk);

        // For identity + unit-gain, the K-th output should equal input[K + skew],
        // where `skew` accounts for the window center being 3 rows and 3 columns
        // behind the input. Search for the alignment automatically:
        //   compare captured[i] against input_mem[i + row_skew*FRAME_W + col_skew]
        // For a first pass, do the naive 1:1 compare and print skew if it fails.
        for (i = 0; i < n_captured; i = i + 1) begin
            if (captured[i] !== expected_mem[i]) begin
                if (errors < 5)  // only print first few
                    $display("MISMATCH[%0d]: got %02h, expected %02h",
                             i, captured[i], expected_mem[i]);
                errors = errors + 1;
            end
        end

        $display("Captured %0d of %0d outputs, %0d mismatches",
                 n_captured, N_PIX, errors);
        if (errors == 0) $display("PASS: numerical verify (identity filter)");
        else             $display("FAIL");
        $finish;
    end
endmodule
