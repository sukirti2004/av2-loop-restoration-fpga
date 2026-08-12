`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.07.2026 22:04:33
// Design Name: 
// Module Name: tb_tap_reg_file
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

module tb_tap_reg_file;
    reg         clk = 0;
    reg         rst = 1;
    reg         wr_en = 0;
    reg  [5:0]  wr_addr = 0;
    reg  [31:0] wr_data = 0;
    reg         swap = 0;
    wire [83:0] taps_live;
    wire [15:0] norm_live;
    integer     errors = 0;
    integer     i;
    reg  [31:0] wdata_tmp;
    reg  [6:0]  exp_tap;

    always #5 clk = ~clk;

    tap_reg_file dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .swap(swap),
        .taps_live(taps_live), .norm_live(norm_live)
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

    task pulse_swap;
        begin
            swap = 1'b1;
            @(posedge clk); #1;
            swap = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // 1. Live outputs must be zero after reset
        if (taps_live !== 84'd0 || norm_live !== 16'd0) begin
            $display("FAIL: live not zero after reset"); errors = errors + 1;
        end

        // 2. Write distinct values to shadow; live must NOT change yet
        for (i = 0; i < 12; i = i + 1) begin
            wdata_tmp = i + 1;                       // taps 1..12
            write_reg(i[5:0], wdata_tmp);
        end
        write_reg(6'd12, 32'h0000_ABCD);             // norm 0xABCD

        if (taps_live !== 84'd0 || norm_live !== 16'd0) begin
            $display("FAIL: live changed without swap"); errors = errors + 1;
        end

        // 3. Pulse swap → live should now equal shadow
        pulse_swap;
        for (i = 0; i < 12; i = i + 1) begin
            exp_tap = i + 1;
            if (taps_live[7*i +: 7] !== exp_tap) begin
                $display("FAIL after swap 1: tap[%0d] = %0d expected %0d",
                         i, taps_live[7*i +: 7], exp_tap);
                errors = errors + 1;
            end
        end
        if (norm_live !== 16'hABCD) begin
            $display("FAIL after swap 1: norm = %h expected ABCD", norm_live);
            errors = errors + 1;
        end

        // 4. Write new values to shadow; live must hold OLD values
        for (i = 0; i < 12; i = i + 1)
            write_reg(i[5:0], 32'h0000_007F);        // all taps → 0x7F (= -1 as int7)
        write_reg(6'd12, 32'h0000_1234);

        for (i = 0; i < 12; i = i + 1) begin
            exp_tap = i + 1;
            if (taps_live[7*i +: 7] !== exp_tap) begin
                $display("FAIL: tap[%0d] changed without swap", i);
                errors = errors + 1;
            end
        end
        if (norm_live !== 16'hABCD) begin
            $display("FAIL: norm changed without swap"); errors = errors + 1;
        end

        // 5. Swap again → live takes new values
        pulse_swap;
        for (i = 0; i < 12; i = i + 1) begin
            if (taps_live[7*i +: 7] !== 7'h7F) begin
                $display("FAIL after swap 2: tap[%0d] = %h",
                         i, taps_live[7*i +: 7]);
                errors = errors + 1;
            end
        end
        if (norm_live !== 16'h1234) begin
            $display("FAIL after swap 2: norm = %h", norm_live);
            errors = errors + 1;
        end

        // 6. Address decode: writes to reserved words must be ignored
        write_reg(6'd13, 32'hDEAD_BEEF);
        write_reg(6'd15, 32'hCAFE_F00D);
        pulse_swap;
        if (norm_live !== 16'h1234) begin
            $display("FAIL: reserved write leaked into norm"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS: all cases match");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule