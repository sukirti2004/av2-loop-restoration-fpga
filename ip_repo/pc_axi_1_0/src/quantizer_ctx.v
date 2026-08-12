`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 23.06.2026 16:27:52
// Design Name: 8 level Quantizer
// Module Name: quantizer
// Project Name: 
// Target Devices: PYNQ-Z2 
// Tool Versions: 
// Description: This Quantizes the 4 features into  8  levels
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module quantizer_ctx (
    input  wire        clk,
    input  wire        resetn,
    input  wire        valid_in,
    input  wire signed [15:0] feat0, feat1, feat2, feat3,
    input  wire [15:0] t0,t1,t2,t3,t4,t5,t6,   // 7 shared thresholds
    output reg  [11:0] ctx_out,
    output reg         valid_out
);

wire [15:0] abs0 = feat0[15] ? -feat0 : feat0;
wire [15:0] abs1 = feat1[15] ? -feat1 : feat1;
wire [15:0] abs2 = feat2[15] ? -feat2 : feat2;
wire [15:0] abs3 = feat3[15] ? -feat3 : feat3;

function [2:0] count_thresh;
    input [15:0] absval;
    input [15:0] t0,t1,t2,t3,t4,t5,t6;
    begin
        count_thresh = (absval>=t0)+(absval>=t1)+(absval>=t2)+
                       (absval>=t3)+(absval>=t4)+(absval>=t5)+(absval>=t6);
    end
endfunction

wire [2:0] lv0 = count_thresh(abs0,t0,t1,t2,t3,t4,t5,t6);
wire [2:0] lv1 = count_thresh(abs1,t0,t1,t2,t3,t4,t5,t6);
wire [2:0] lv2 = count_thresh(abs2,t0,t1,t2,t3,t4,t5,t6);
wire [2:0] lv3 = count_thresh(abs3,t0,t1,t2,t3,t4,t5,t6);

always @(posedge clk) begin
    if (!resetn) begin ctx_out <= 12'b0; valid_out <= 1'b0; end
    else begin
        valid_out <= valid_in;
        if (valid_in) ctx_out <= {lv3,lv2,lv1,lv0};
    end
end
endmodule