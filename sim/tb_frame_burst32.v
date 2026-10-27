`timescale 1ns/1ps
// Verify that a 32-beat DDR read burst completes before the next AR address.
// Compile together with tb_frame_ring_ctrl.v for the small FIFO models.

module tb_frame_burst32;

localparam integer H = 1280;
localparam integer V = 2;
localparam integer RB = 32;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

wire [31:0] awaddr;
wire [7:0]  awlen;
wire        awvalid;
reg         awready = 1'b1;
wire [127:0] wdata;
wire [15:0] wstrb;
wire        wlast, wvalid;
reg         wready = 1'b1;
wire        bready;
reg  [3:0]  bid = 0;
reg  [1:0]  bresp = 0;
reg         bvalid = 0;

wire [3:0]  arid;
wire [31:0] araddr;
wire [7:0]  arlen;
wire [2:0]  arsize;
wire [1:0]  arburst;
wire        arlock;
wire [3:0]  arcache;
wire [2:0]  arprot;
wire [3:0]  arqos;
wire        arvalid;
reg         arready = 1'b1;

reg  [3:0]   rid = 0;
reg  [127:0] axi_rdata = 0;
reg  [1:0]   rresp = 0;
reg          rlast = 0;
reg          rvalid = 0;
wire         rready;

wire [15:0] rdata;
wire        rdata_valid;
reg         rd_en = 1'b1;
reg         rvsync = 1'b0;
reg  [1:0]  mode = 2'd0;
reg         prev_pulse = 0, next_pulse = 0;
wire [6:0]  live_slot, freeze_slot, replay_slot, ring_count, write_slot;
wire        write_slot_tog, commit, live_valid_dut;

integer errors = 0;
integer ar_count = 0;
integer beat = 0;
integer max_y = 0;
reg [31:0] ar_addr [0:15];
reg [31:0] active_addr;
reg [31:0] ar_queue [0:15];
integer ar_head = 0;
integer ar_tail = 0;
integer ar_queued = 0;

always @(posedge clk) begin
	if (dut.out_y > max_y)
		max_y = dut.out_y;

	if (!rvalid && (ar_queued != 0)) begin
		active_addr = ar_queue[ar_head];
		ar_head = (ar_head == 15) ? 0 : ar_head + 1;
		ar_queued = ar_queued - 1;
		beat = 0;
		rvalid <= 1'b1;
		rlast <= 1'b0;
		axi_rdata <= active_addr;
	end else if (rvalid && rready) begin
		if (rlast) begin
			rvalid <= 1'b0;
			rlast <= 1'b0;
			beat = 0;
		end else begin
			beat = beat + 1;
			rlast <= (beat == RB-1);
			axi_rdata <= active_addr + beat*16;
		end
	end

	// AXI permits AR to be accepted while previous R bursts are active.
	if (arvalid && arready) begin
		if (ar_count < 16)
			ar_addr[ar_count] = araddr;
		ar_count = ar_count + 1;
		ar_queue[ar_tail] = araddr;
		ar_tail = (ar_tail == 15) ? 0 : ar_tail + 1;
		ar_queued = ar_queued + 1;
	end
end

frame_ring_ctrl #(
	.H_ACTIVE(H),
	.V_ACTIVE(V),
	.N_FRAMES(2),
	.SLOT_BYTES(32'h0000_4000),
	.MED_OFFSET(32'h0000_2000),
	.W_BURST(2),
	.R_BURST(RB)
) dut (
	.axi_awid(), .axi_awaddr(awaddr), .axi_awlen(awlen), .axi_awsize(),
	.axi_awburst(), .axi_awlock(), .axi_awcache(), .axi_awprot(), .axi_awqos(),
	.axi_awvalid(awvalid), .axi_awready(awready),
	.axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wlast(wlast),
	.axi_wvalid(wvalid), .axi_wready(wready),
	.axi_bid(bid), .axi_bresp(bresp), .axi_bvalid(bvalid), .axi_bready(bready),
	.axi_arid(arid), .axi_araddr(araddr), .axi_arlen(arlen), .axi_arsize(arsize),
	.axi_arburst(arburst), .axi_arlock(arlock), .axi_arcache(arcache),
	.axi_arprot(arprot), .axi_arqos(arqos), .axi_arvalid(arvalid), .axi_arready(arready),
	.axi_rid(rid), .axi_rdata(axi_rdata), .axi_rresp(rresp), .axi_rlast(rlast),
	.axi_rvalid(rvalid), .axi_rready(rready),
	.axi_clk(clk), .axi_reset(rst),
	.wframe_clk(clk), .wframe_rst(rst), .wframe_sop(1'b0), .wframe_eop(1'b0),
	.wframe_valid(1'b0), .wframe_raw(16'd0), .wframe_gray(8'd0),
	.rframe_clk(clk), .rframe_rst(rst), .rframe_vsync(rvsync),
	.rframe_data_en(rd_en), .rframe_data(rdata), .rframe_data_valid(rdata_valid),
	.display_mode(mode), .prev_frame(prev_pulse), .next_frame(next_pulse),
	.live_slot(live_slot), .freeze_slot(freeze_slot), .replay_slot(replay_slot),
	.ring_count(ring_count), .write_slot(write_slot),
	.write_slot_toggle(write_slot_tog), .frame_commit(commit),
	.live_valid(live_valid_dut), .read_debug(), .out_data_seen()
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
	repeat (20) @(posedge clk);
	rst = 1'b0;
	repeat (10) @(posedge clk);
	dut.live_valid = 1'b1;
	rvsync = 1'b1;
	repeat (2) @(posedge clk);
	rvsync = 1'b0;

	repeat (10000) @(posedge clk);
	$display("   ar_count=%0d max_y=%0d addr0=%08x addr1=%08x addr4=%08x addr5=%08x",
		ar_count, max_y, ar_addr[0], ar_addr[1], ar_addr[4], ar_addr[5]);
	check(ar_count == 10, "two rows issue five 32-beat bursts each");
	check(arlen == RB-1, "ARLEN remains 31");
	check(max_y >= V-1, "reader reaches the final display row");
	check(ar_addr[0] == 32'h0000_0000, "first burst address");
	check(ar_addr[1] == 32'h0000_0200, "second burst advances by 512 bytes");
	check(ar_addr[4] == 32'h0000_0800, "fifth burst ends row 0");
	check(ar_addr[5] == 32'h0000_0A00, "next row starts at 2560 bytes");

	$display("==============================================");
	if (errors == 0)
		$display(" RESULT: ALL CHECKS PASSED");
	else
		$display(" RESULT: %0d CHECK(S) FAILED", errors);
	$finish;
end

endmodule
