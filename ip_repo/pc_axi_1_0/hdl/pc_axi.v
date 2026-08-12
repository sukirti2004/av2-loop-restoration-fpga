`timescale 1 ns / 1 ps

	module pc_axi #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line

		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 5,

		// Parameters of Axi Slave Bus Interface S00_AXIS
		parameter integer C_S00_AXIS_TDATA_WIDTH	= 32,

		// Parameters of Axi Master Bus Interface M00_AXIS
		parameter integer C_M00_AXIS_TDATA_WIDTH	= 32,
		parameter integer C_M00_AXIS_START_COUNT	= 32
	)
	(
		// Users to add ports here

		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready,

		// Ports of Axi Slave Bus Interface S00_AXIS
		input wire  s00_axis_aclk,
		input wire  s00_axis_aresetn,
		output wire  s00_axis_tready,
		input wire [C_S00_AXIS_TDATA_WIDTH-1 : 0] s00_axis_tdata,
		input wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
		input wire  s00_axis_tlast,
		input wire  s00_axis_tvalid,

		// Ports of Axi Master Bus Interface M00_AXIS
		input wire  m00_axis_aclk,
		input wire  m00_axis_aresetn,
		output wire  m00_axis_tvalid,
		output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0] m00_axis_tdata,
		output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
		output wire  m00_axis_tlast,
		input wire  m00_axis_tready
	);

	// Internal wires: threshold values from AXI-Lite registers to filter core
	// These carry the Q2.14 fixed-point thresholds written by PYNQ Python
	wire [15:0] w_t0, w_t1, w_t2, w_t3, w_t4, w_t5, w_t6;
	// Internal wires: image dimensions from AXI-Lite register 7
	// img_width and img_height are written by PYNQ before streaming begins
	wire [10:0] w_img_width;
	wire [10:0] w_img_height;
	
	// Registered pixel count: (img_width-6)*(img_height-6)
    // Registered to avoid a long combinational multiply on critical path
    reg [21:0] r_pixel_count;
    always @(posedge s00_axi_aclk)
        r_pixel_count <= (w_img_width - 11'd6) * (w_img_height - 11'd6);

	// Internal wires: pixel data path from AXI-Stream slave to line_buffer
	// One pixel per clock, 8-bit unsigned, extracted from 32-bit TDATA[7:0]
	wire [7:0]  w_pixel_in;
	wire        w_pixel_in_valid;

	// Internal wires: 7x7 patch from line_buffer to pc_filter_core
	// 49 pixels x 8 bits = 392-bit flat bus, valid when a full patch is ready
	wire [49*8-1:0] w_patch_flat;
	wire            w_patch_valid;

	// Internal wires: filtered pixel from pc_filter_core to AXI-Stream master
	// One filtered pixel per clock when valid, sent back to PYNQ via DMA
	wire [7:0]  w_pixel_filtered;
	wire        w_filtered_valid;

	// Instantiation of Axi Bus Interface S00_AXI
	// Handles AXI-Lite register writes/reads from PYNQ ARM processor.
	// Exposes 8 registers: slv_reg0-6 = thresholds t0-t6, slv_reg7 = image dims.
	pc_axi_slave_lite_v1_0_S00_AXI # (
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) pc_axi_slave_lite_v1_0_S00_AXI_inst (
		.S_AXI_ACLK(s00_axi_aclk),
		.S_AXI_ARESETN(s00_axi_aresetn),
		.S_AXI_AWADDR(s00_axi_awaddr),
		.S_AXI_AWPROT(s00_axi_awprot),
		.S_AXI_AWVALID(s00_axi_awvalid),
		.S_AXI_AWREADY(s00_axi_awready),
		.S_AXI_WDATA(s00_axi_wdata),
		.S_AXI_WSTRB(s00_axi_wstrb),
		.S_AXI_WVALID(s00_axi_wvalid),
		.S_AXI_WREADY(s00_axi_wready),
		.S_AXI_BRESP(s00_axi_bresp),
		.S_AXI_BVALID(s00_axi_bvalid),
		.S_AXI_BREADY(s00_axi_bready),
		.S_AXI_ARADDR(s00_axi_araddr),
		.S_AXI_ARPROT(s00_axi_arprot),
		.S_AXI_ARVALID(s00_axi_arvalid),
		.S_AXI_ARREADY(s00_axi_arready),
		.S_AXI_RDATA(s00_axi_rdata),
		.S_AXI_RRESP(s00_axi_rresp),
		.S_AXI_RVALID(s00_axi_rvalid),
		.S_AXI_RREADY(s00_axi_rready),
		// User-added output ports: expose register values to pipeline
		.o_t0(w_t0),
		.o_t1(w_t1),
		.o_t2(w_t2),
		.o_t3(w_t3),
		.o_t4(w_t4),
		.o_t5(w_t5),
		.o_t6(w_t6),
		.o_img_width(w_img_width),
		.o_img_height(w_img_height)
	);

	// Instantiation of Axi Bus Interface S00_AXIS
	// Receives pixel stream from AXI-DMA and passes pixels to line_buffer.
	// Always asserts TREADY (never applies backpressure) since our pipeline
	// can accept one pixel every clock cycle.
	pc_axi_slave_stream_v1_0_S00_AXIS # (
		.C_S_AXIS_TDATA_WIDTH(C_S00_AXIS_TDATA_WIDTH)
	) pc_axi_slave_stream_v1_0_S00_AXIS_inst (
		.S_AXIS_ACLK(s00_axis_aclk),
		.S_AXIS_ARESETN(s00_axis_aresetn),
		.S_AXIS_TREADY(s00_axis_tready),
		.S_AXIS_TDATA(s00_axis_tdata),
		.S_AXIS_TSTRB(s00_axis_tstrb),
		.S_AXIS_TLAST(s00_axis_tlast),
		.S_AXIS_TVALID(s00_axis_tvalid),
		// User-added output ports: pixel data and valid to pipeline
		.pixel_out(w_pixel_in),
		.pixel_valid(w_pixel_in_valid)
	);

	// Instantiation of Axi Bus Interface M00_AXIS
	// Sends filtered interior pixels back to PYNQ via AXI-DMA.
	// Drives TVALID directly from pc_filter_core valid signal.
	// PYNQ ARM reconstructs the full image by overlaying these pixels
	// onto a copy of the input at positions [3:-3, 3:-3].
	pc_axi_master_stream_v1_0_M00_AXIS # (
		.C_M_AXIS_TDATA_WIDTH(C_M00_AXIS_TDATA_WIDTH),
		.C_M_START_COUNT(C_M00_AXIS_START_COUNT)
	) pc_axi_master_stream_v1_0_M00_AXIS_inst (
		.M_AXIS_ACLK(m00_axis_aclk),
		.M_AXIS_ARESETN(m00_axis_aresetn),
		.M_AXIS_TVALID(m00_axis_tvalid),
		.M_AXIS_TDATA(m00_axis_tdata),
		.M_AXIS_TSTRB(m00_axis_tstrb),
		.M_AXIS_TLAST(m00_axis_tlast),
		.M_AXIS_TREADY(m00_axis_tready),
		// User-added input ports: filtered pixel data from pipeline
		.pixel_in(w_pixel_filtered),
		.pixel_valid(w_filtered_valid),
		.pixel_count(r_pixel_count)
	);

	// Add user logic here

	// line_buffer: accumulates incoming pixels into a sliding 7x7 window.
	// Outputs a valid 49-pixel flat patch once 7 complete rows have been
	// buffered and the column index is >= 6. Border pixels (first/last 3
	// rows and columns) are handled on the PYNQ ARM side.
	// Uses s00_axi_aclk as clock — same physical clock as all interfaces.
	pc_line_buffer #(.MAX_W(1920)) u_lb (
		.clk        (s00_axi_aclk),
		.resetn     (s00_axi_aresetn),
		.valid_in   (w_pixel_in_valid),
		.pixel_in   (w_pixel_in),
		.img_width  (w_img_width),
		.img_height (w_img_height),
		.pixels_flat(w_patch_flat),
		.valid_out  (w_patch_valid)
	);

	// pc_filter_core: 5-stage pipeline implementing the PC filter.
	// Stages: feature_compute -> quantizer_ctx -> cluster_lut ->
	//         filter_lut -> mac_engine.
	// Total latency: 5 clock cycles from patch_valid to pixel_out valid.
	pc_filter_core u_core (
		.clk        (s00_axi_aclk),
		.resetn     (s00_axi_aresetn),
		.valid_in   (w_patch_valid),
		.pixels_flat(w_patch_flat),
		.t0(w_t0), .t1(w_t1), .t2(w_t2), .t3(w_t3),
		.t4(w_t4), .t5(w_t5), .t6(w_t6),
		.pixel_out  (w_pixel_filtered),
		.valid_out  (w_filtered_valid)
	);

	// User logic ends

	endmodule