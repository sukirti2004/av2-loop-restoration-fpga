`timescale 1 ns / 1 ps

module ns_filter_slave_stream_v1_0_S00_AXIS #
(
    // Users to add parameters here

    // User parameters ends
    // Do not modify the parameters beyond this line

    // AXI4Stream sink
    parameter integer C_S_AXIS_TDATA_WIDTH = 32
)
(
    // Users to add ports here
    // ---- Exposed pass-through signals to the pipeline (ns_filter_top) ----
    output wire       pix_valid,
    output wire [7:0] pix_data,
    // User ports ends
    // Do not modify the ports beyond this line

    // AXI4Stream sink: Clock
    input  wire S_AXIS_ACLK,
    // AXI4Stream sink: Reset (active LOW)
    input  wire S_AXIS_ARESETN,
    // Ready to accept data in
    output wire S_AXIS_TREADY,
    // Data in
    input  wire [C_S_AXIS_TDATA_WIDTH-1 : 0] S_AXIS_TDATA,
    // Byte qualifier
    input  wire [(C_S_AXIS_TDATA_WIDTH/8)-1 : 0] S_AXIS_TSTRB,
    // Indicates boundary of last packet
    input  wire S_AXIS_TLAST,
    // Data valid
    input  wire S_AXIS_TVALID
);

    // Pipeline never asserts backpressure (DMA-batch design), so we're always
    // ready to accept the next pixel.
    assign S_AXIS_TREADY = 1'b1;

    // Straight-through: expose the AXI-Stream data + valid to the pipeline.
    assign pix_valid = S_AXIS_TVALID;
    assign pix_data  = S_AXIS_TDATA[7:0];

    // TSTRB and TLAST are ignored - not used by the downstream filter.

endmodule