`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.06.2026 13:54:53
// Design Name: 
// Module Name: tb_filter_LUT
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

module tb_filter_lut;

reg        clk       = 0;
reg        valid_in  = 0;
reg [7:0]  filter_id = 0;

wire [49*16-1:0] taps_flat;
wire             valid_out;

always #5 clk = ~clk;

filter_lut uut (
    .clk(clk),
    .valid_in(valid_in),
    .filter_id(filter_id),
    .taps_flat(taps_flat),
    .valid_out(valid_out)
);

// helper to extract tap i as signed 16-bit
`define GET_TAP(i) $signed(taps_flat[i*16 +: 16])

task lookup_and_print;
    input [7:0] fid;
begin
    filter_id = fid;
    valid_in  = 1;
    @(posedge clk); #1;
    valid_in  = 0;
    @(posedge clk); #1;
    $display("filter_id=%0d tap0=%0d tap1=%0d tap2=%0d tap3=%0d tap4=%0d",
              fid,
              `GET_TAP(0), `GET_TAP(1), `GET_TAP(2),
              `GET_TAP(3), `GET_TAP(4));
end
endtask

initial begin
    #20;
    lookup_and_print(8'd0);
    lookup_and_print(8'd1);
    lookup_and_print(8'd255);
    #20;
    $display("Filter LUT test complete.");
    $finish;
end

endmodule
