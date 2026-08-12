`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 23.06.2026 17:34:29
// Design Name: 
// Module Name: cluster_lut
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

module cluster_lut (
    input  wire        clk,
    input  wire        valid_in,
    input  wire [11:0] ctx_in,

    output reg  [7:0]  filter_id,
    output reg         valid_out
);

// 4096 x 8-bit - Vivado infers this as BRAM automatically
reg [7:0] mem [0:4095];

// load cluster_map values from hex file
initial begin
    $readmemh("E:/ELIM_NonSeparable_V2_0/vivado/fpga_pc/cluster_map.hex", mem);
end

always @(posedge clk) begin
    valid_out <= valid_in;
    filter_id <= mem[ctx_in];
end

endmodule