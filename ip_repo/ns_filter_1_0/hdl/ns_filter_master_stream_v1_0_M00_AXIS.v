`timescale 1 ns / 1 ps

module ns_filter_master_stream_v1_0_M00_AXIS #
(
    // Users to add parameters here

    // User parameters ends
    // Do not modify the parameters beyond this line

    // AXI4Stream source
    parameter integer C_M_AXIS_TDATA_WIDTH  = 32,
    // Kept for wizard XML compatibility; unused now.
    parameter integer C_M_START_COUNT       = 32
)
(
    // Users to add ports here
    // ---- Pipeline signals coming in (from ns_filter_top) ----
    input  wire       pix_valid,
    input  wire [7:0] pix_data,
    // User ports ends
    // Do not modify the ports beyond this line

    // Global ports
    input  wire M_AXIS_ACLK,
    input  wire M_AXIS_ARESETN,
    // Master Stream Ports
    output wire M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1 : 0] M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] M_AXIS_TSTRB,
    output wire M_AXIS_TLAST,
    input  wire M_AXIS_TREADY
);

    // Direct pass-through of the pipeline's filtered pixel to the AXI-Stream master.
    assign M_AXIS_TVALID = pix_valid;
    assign M_AXIS_TDATA  = pix_data;
    assign M_AXIS_TSTRB  = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};
    assign M_AXIS_TLAST  = 1'b0;   // DMA doesn't rely on TLAST for batch transfers

    // NOTE: M_AXIS_TREADY is intentionally ignored. The pipeline is always-flowing
    // (per the "no backpressure" design decision), and the DMA's internal FIFO
    // keeps TREADY high during transfers. If robust backpressure ever becomes
    // needed, drop an "AXI4-Stream Register Slice" IP between this master and
    // the DMA in the block design - no RTL change here.

endmodule