`timescale 1ns/1ps
// Verify the time-multiplexed display reader:
//   black bar first, then live raw row 0, then historical median row 0.
// Compile together with tb_frame_ring_ctrl.v so the stub FIFO modules are
// available and the macro is not hidden by a pre-existing compiled library.

module tb_frame_ring_read;

localparam integer H = 16;
localparam integer V = 720;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

wire [31:0] awaddr;
wire [7:0] awlen;
wire awvalid;
reg awready = 1'b1;
wire [127:0] wdata;
wire [15:0] wstrb;
wire wlast, wvalid;
reg wready = 1'b1;
wire bready;
reg [3:0] bid = 0;
reg [1:0] bresp = 0;
reg bvalid = 0;

wire [3:0] arid;
wire [31:0] araddr;
wire [7:0] arlen;
wire [2:0] arsize;
wire [1:0] arburst;
wire arlock;
wire [3:0] arcache;
wire [2:0] arprot;
wire [3:0] arqos;
wire arvalid;
reg arready = 1'b1;

reg [3:0] rid = 0;
reg [127:0] axi_rdata = 0;
reg [1:0] rresp = 0;
reg rlast = 0;
reg rvalid = 0;
wire rready;

wire [15:0] rd_data;
reg rd_en = 1'b0;
reg rvsync = 1'b0;
reg [1:0] mode = 2'd1;
reg prev_pulse = 0, next_pulse = 0;
wire [6:0] live_slot, freeze_slot, replay_slot, ring_count, write_slot;
wire write_slot_tog, commit, live_valid_dut;

integer errors = 0;
integer ar_count = 0;
integer max_y = 0;
integer ar_addr [0:7];
integer cycles = 0;
integer beat = 0;
reg [31:0] active_ar_addr;

always @(posedge clk) begin
	if (dut.out_y > max_y)
		max_y = dut.out_y;
	if (rvalid && rready) begin
		if (rlast) begin
			rvalid = 0;
			rlast = 0;
			beat = 0;
		end else begin
			beat = beat + 1;
			rlast = 1;
			axi_rdata = {8{active_ar_addr[15:0]}};
		end
	end else if (arvalid && arready && !rvalid) begin
		active_ar_addr = araddr;
		if (ar_count < 8)
			ar_addr[ar_count] = araddr;
		ar_count = ar_count + 1;
		rvalid = 1;
		beat = 0;
		rlast = 0;
		axi_rdata = {8{araddr[15:0]}};
	end
	if (cycles < 30000)
		cycles = cycles + 1;
end

frame_ring_ctrl #(
	.H_ACTIVE(H),
	.V_ACTIVE(V),
	.N_FRAMES(4),
	.SLOT_BYTES(32'h0000_1000),
	.MED_OFFSET(32'h0000_0200),
	.W_BURST(1),
	.R_BURST(2)
) dut (
	.axi_awid(),
	.axi_awaddr(awaddr),
	.axi_awlen(awlen),
	.axi_awsize(),
	.axi_awburst(),
	.axi_awlock(),
	.axi_awcache(),
	.axi_awprot(),
	.axi_awqos(),
	.axi_awvalid(awvalid),
	.axi_awready(awready),
	.axi_wdata(wdata),
	.axi_wstrb(wstrb),
	.axi_wlast(wlast),
	.axi_wvalid(wvalid),
	.axi_wready(wready),
	.axi_bid(bid),
	.axi_bresp(bresp),
	.axi_bvalid(bvalid),
	.axi_bready(bready),
	.axi_arid(arid),
	.axi_araddr(araddr),
	.axi_arlen(arlen),
	.axi_arsize(arsize),
	.axi_arburst(arburst),
	.axi_arlock(arlock),
	.axi_arcache(arcache),
	.axi_arprot(arprot),
	.axi_arqos(arqos),
	.axi_arvalid(arvalid),
	.axi_arready(arready),
	.axi_rid(rid),
	.axi_rdata(axi_rdata),
	.axi_rresp(rresp),
	.axi_rlast(rlast),
	.axi_rvalid(rvalid),
	.axi_rready(rready),
	.axi_clk(clk),
	.axi_reset(rst),
	.wframe_clk(clk),
	.wframe_rst(rst),
	.wframe_sop(1'b0),
	.wframe_eop(1'b0),
	.wframe_valid(1'b0),
	.wframe_raw(16'd0),
	.wframe_gray(8'd0),
	.rframe_clk(clk),
	.rframe_rst(rst),
	.rframe_vsync(rvsync),
	.rframe_data_en(rd_en),
	.rframe_data(rd_data),
	.rframe_data_valid(),
	.display_mode(mode),
	.prev_frame(prev_pulse),
	.next_frame(next_pulse),
	.live_slot(live_slot),
	.freeze_slot(freeze_slot),
	.replay_slot(replay_slot),
	.ring_count(ring_count),
	.write_slot(write_slot),
	.write_slot_toggle(write_slot_tog),
	.frame_commit(commit),
	.live_valid(live_valid_dut),
	.read_debug(),
	.out_data_seen()
);

task check(input integer cond, input [8*80:1] name);
begin
	if (cond)
		$display("   [PASS] %0s", name);
	else begin
		$display("   [FAIL] %0s", name);
		errors = errors + 1;
	end
end
endtask

initial begin
	rd_en = 1'b1;
	repeat(20) @(posedge clk);
	rst = 1'b0;
	repeat(10) @(posedge clk);
	dut.live_valid = 1'b1;

	rvsync = 1'b1;
	repeat(2) @(posedge clk);
	rvsync = 1'b0;

	repeat(100000) @(posedge clk);
	check(ar_count >= 4, "reader issued source-row transactions");
	check(ar_addr[0] == 32'h0000_0000,
		"left image row 0 reads live raw plane");
	check(ar_addr[1] == 32'h0000_0200,
		"right image row 0 reads frozen median plane");
	check(ar_addr[2] == 32'h0000_0040,
		"left image row 1 reads live raw row 2 (2x vertical)");
	check(ar_addr[3] == 32'h0000_0240,
		"right image row 1 reads frozen median row 2");
	$display("   reader max_y=%0d ar_count=%0d", max_y, ar_count);
	check(max_y >= V-1, "reader generated all 720 display rows");

	$display("==============================================");
	if (errors == 0)
		$display(" RESULT: ALL CHECKS PASSED");
	else
		$display(" RESULT: %0d CHECK(S) FAILED", errors);
	$finish;
end

endmodule
