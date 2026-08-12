`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 23.06.2026 17:40:44
// Design Name: 
// Module Name: tb_cluster_lut
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

module tb_cluster_lut;

reg        clk    = 0;
reg        valid_in = 0;
reg [11:0] ctx_in   = 0;

wire [7:0] filter_id;
wire       valid_out;

always #5 clk = ~clk;

cluster_lut uut (
    .clk(clk),
    .valid_in(valid_in),
    .ctx_in(ctx_in),
    .filter_id(filter_id),
    .valid_out(valid_out)
);

task lookup_and_print;
    input [11:0] ctx;
begin
    ctx_in   = ctx;
    valid_in = 1;
    @(posedge clk); #1;
    valid_in = 0;
    @(posedge clk); #1;
    $display("ctx=%0d -> filter_id=%0d", ctx, filter_id);
end
endtask

initial begin
    #20;

    // look up a few context indices and print filter IDs
    lookup_and_print(12'd0);
    lookup_and_print(12'd1);
    lookup_and_print(12'd100);
    lookup_and_print(12'd512);
    lookup_and_print(12'd4095);

    #20;
    $display("Cluster LUT test complete.");
    $finish;
end

endmodule
