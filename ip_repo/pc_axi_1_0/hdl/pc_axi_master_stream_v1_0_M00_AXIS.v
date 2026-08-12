`timescale 1 ns / 1 ps

module pc_axi_master_stream_v1_0_M00_AXIS #
(
    parameter integer C_M_AXIS_TDATA_WIDTH = 32,
    parameter integer C_M_START_COUNT      = 32
)
(
    // NEW: total interior pixels = (H-6)*(W-6), set before transfer
    input wire [21:0] pixel_count,

    // existing user ports
    input wire [7:0]  pixel_in,
    input wire        pixel_valid,

    input wire  M_AXIS_ACLK,
    input wire  M_AXIS_ARESETN,
    output wire M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1:0] M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1:0] M_AXIS_TSTRB,
    output wire M_AXIS_TLAST,
    input wire  M_AXIS_TREADY
);

    reg [21:0] cnt;

    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN)
            cnt <= 22'd0;
        else if (pixel_valid && M_AXIS_TREADY) begin
            if (cnt + 22'd1 >= pixel_count)
                cnt <= 22'd0;
            else
                cnt <= cnt + 22'd1;
        end
    end

    assign M_AXIS_TVALID = pixel_valid;
    assign M_AXIS_TDATA  = {{(C_M_AXIS_TDATA_WIDTH-8){1'b0}}, pixel_in};
    assign M_AXIS_TSTRB  = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};
    assign M_AXIS_TLAST  = pixel_valid && (cnt + 22'd1 >= pixel_count);

endmodule