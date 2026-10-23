`timescale 1ns/1ps
// Standalone policy test for frame_ring_ctrl. Compile with
// +define+DYC_FRAME_STUB_FIFOS so the vendor FIFOs are replaced by the
// lightweight simulation models below.
`ifdef DYC_FRAME_STUB_FIFOS

module W0_FIFO_16 (
	output reg prog_full_o,
	output wire full_o,
	output reg empty_o,
	output reg prog_empty_o,
	input wr_clk_i,
	input rd_clk_i,
	input wr_en_i,
	input rd_en_i,
	input [15:0] wdata,
	output wire rst_busy,
	output reg [127:0] rdata,
	input a_rst_i,
	output reg [12:0] wr_datacount_o,
	output wire [9:0] rd_datacount_o,
	output wire underflow_o,
	output wire overflow_o
);
	reg [15:0] mem [0:65535];
	integer wp, rp;
	assign full_o = 1'b0;
	assign rst_busy = 1'b0;
	assign rd_datacount_o = 10'd0;
	assign underflow_o = 1'b0;
	assign overflow_o = 1'b0;

	always @(posedge wr_clk_i) begin
		if (a_rst_i) begin
			wp = 0; rp = 0;
			prog_full_o = 1'b0;
			empty_o = 1'b1;
			prog_empty_o = 1'b1;
			wr_datacount_o = 13'd0;
			rdata = 128'd0;
		end else begin
			if (wr_en_i) begin
				mem[wp] = wdata;
				wp = wp + 1;
			end
			if (rd_en_i && ((wp-rp) >= 8))
				rp = rp + 8;
			empty_o = (wp == rp);
			prog_empty_o = ((wp-rp) < 8);
			wr_datacount_o = wp-rp;
			{rdata[127:112],rdata[111:96],rdata[95:80],rdata[79:64],
			 rdata[63:48],rdata[47:32],rdata[31:16],rdata[15:0]} =
				{mem[rp+7],mem[rp+6],mem[rp+5],mem[rp+4],
				 mem[rp+3],mem[rp+2],mem[rp+1],mem[rp]};
		end
	end
endmodule

module R0_FIFO_16 (
	output wire almost_full_o,
	output reg prog_full_o,
	output wire full_o,
	output wire wr_ack_o,
	output reg empty_o,
	output wire almost_empty_o,
	output wire rd_valid_o,
	input wr_clk_i,
	input rd_clk_i,
	input wr_en_i,
	input rd_en_i,
	input [127:0] wdata,
	output wire rst_busy,
	output reg [15:0] rdata,
	input a_rst_i,
	output wire [9:0] wr_datacount_o,
	output wire [12:0] rd_datacount_o,
	output wire underflow_o,
	output wire overflow_o
);
	reg [15:0] mem [0:65535];
	integer wp, rp;
	assign almost_full_o = 1'b0;
	assign full_o = 1'b0;
	assign wr_ack_o = 1'b0;
	assign almost_empty_o = 1'b0;
	assign rd_valid_o = !empty_o;
	assign rst_busy = 1'b0;
	assign wr_datacount_o = 10'd0;
	assign rd_datacount_o = 13'd0;
	assign underflow_o = 1'b0;
	assign overflow_o = 1'b0;

	always @(posedge wr_clk_i) begin
		if (a_rst_i) begin
			wp = 0; rp = 0;
			prog_full_o = 1'b0;
			empty_o = 1'b1;
			rdata = 16'd0;
		end else begin
			if (wr_en_i) begin
				{mem[wp+7],mem[wp+6],mem[wp+5],mem[wp+4],
				 mem[wp+3],mem[wp+2],mem[wp+1],mem[wp]} = wdata;
				wp = wp + 8;
			end
			if (rd_en_i && (rp != wp)) begin
				rdata = mem[rp];
				rp = rp + 1;
			end
			empty_o = (wp == rp);
			prog_full_o = ((wp-rp) > 2048);
		end
	end
endmodule

`endif

module tb_frame_ring_ctrl;

localparam integer H = 16;
localparam integer V = 4;
localparam integer NPIX = H*V;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

reg w_sop, w_eop, w_valid;
reg [15:0] w_raw;
reg [7:0]  w_gray;
reg [1:0]  mode;
reg        prev_pulse, next_pulse;
reg        rvsync;
reg        rd_en;

wire [15:0] rdata;
wire [6:0] live_slot, freeze_slot, replay_slot, ring_count, write_slot;
wire write_slot_tog, commit;

wire [31:0] awaddr;
wire [7:0] awlen;
wire awvalid;
reg awready;
wire [127:0] wdata;
wire [15:0] wstrb;
wire wlast, wvalid;
reg wready;
reg [3:0] bid;
reg [1:0] bresp;
reg bvalid;
wire bready;
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
reg arready;
reg [3:0] rid;
reg [127:0] axi_rdata;
reg [1:0] rresp;
reg rlast, rvalid;
wire rready;

integer errors = 0;
reg [2:0] bdelay = 0;

always @(posedge clk) begin
	if (wvalid && wready && wlast)
		bdelay <= 3'd2;
	else if (bdelay != 0)
		bdelay <= bdelay - 1'b1;
	bvalid <= (bdelay == 3'd1);
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
	.wframe_sop(w_sop),
	.wframe_eop(w_eop),
	.wframe_valid(w_valid),
	.wframe_raw(w_raw),
	.wframe_gray(w_gray),
	.rframe_clk(clk),
	.rframe_rst(rst),
	.rframe_vsync(rvsync),
	.rframe_data_en(rd_en),
	.rframe_data(rdata),
	.display_mode(mode),
	.prev_frame(prev_pulse),
	.next_frame(next_pulse),
	.live_slot(live_slot),
	.freeze_slot(freeze_slot),
	.replay_slot(replay_slot),
	.ring_count(ring_count),
	.write_slot(write_slot),
	.write_slot_toggle(write_slot_tog),
	.frame_commit(commit)
);

task send_frame(input [15:0] tag);
	integer i;
begin
	@(negedge clk);
	w_sop = 1'b1; w_valid = 1'b1;
	w_raw = tag; w_gray = tag[7:0];
	for (i=1; i<NPIX; i=i+1) begin
		@(negedge clk);
		w_sop = 1'b0;
		w_raw = tag + i;
		w_gray = tag[7:0] + i[7:0];
	end
	@(posedge clk);
	@(negedge clk);
	w_valid = 1'b0;
	w_eop = 1'b1;
	@(negedge clk);
	w_eop = 1'b0;
end
endtask

task wait_commit;
	integer n;
begin
	n = 0;
	while (!commit && (n < 2000)) begin
		@(posedge clk);
		n = n + 1;
	end
	check(commit, "frame commit pulse observed");
	@(posedge clk);
end
endtask

task check(input integer cond, input [8*72:1] name);
begin
	if (cond)
		$display("   [PASS] %0s", name);
	else begin
		$display("   [FAIL] %0s ring=%0d live=%0d write=%0d", name,
			ring_count, live_slot, write_slot);
		errors = errors + 1;
	end
end
endtask

initial begin
	w_sop=0; w_eop=0; w_valid=0; w_raw=0; w_gray=0;
	mode=0; prev_pulse=0; next_pulse=0;
	rvsync=0; rd_en=0;
	awready=1; wready=1; bvalid=0; bid=0; bresp=0;
	arready=1;
	rid=0; axi_rdata=0; rresp=0; rlast=0; rvalid=0;
	repeat(20) @(posedge clk);
	rst = 0;
	repeat(10) @(posedge clk);

	send_frame(16'h1000);
	wait_commit;
	check((ring_count == 1) && (write_slot == 0) && (live_slot == 0),
		"first live frame recorded in ring slot 0");
	check((dut.raw_ptr >= NPIX*2) && (dut.med_ptr >= NPIX*2),
		"raw and median planes both written");

	send_frame(16'h2000);
	wait_commit;
	check((ring_count == 2) && (live_slot == 1),
		"second live frame advances ring to slot 1");

	mode = 1; #100;
	send_frame(16'h3000);
	wait_commit;
	check((ring_count == 2) && (live_slot == 100) && (freeze_slot == 1),
		"freeze uses scratch slot and pins previous complete frame");
	check(dut.frame_target_slot == 7'd100, "scratch frame targets slot 100");

	mode = 2; #100;
	check(replay_slot == 1, "replay starts from newest history frame");

	mode = 0; #100;
	send_frame(16'h4000); wait_commit;
	send_frame(16'h5000); wait_commit;
	send_frame(16'h6000); wait_commit;
	check((ring_count == 4) && (write_slot == 0) && (live_slot == 0),
		"ring wraps modulo 4 and newest frame replaces slot 0");

	$display("==============================================");
	if (errors == 0)
		$display(" RESULT: ALL CHECKS PASSED");
	else
		$display(" RESULT: %0d CHECK(S) FAILED", errors);
	$finish;
end

initial begin
	#2_000_000;
	$display(" TIMEOUT");
	$finish;
end

endmodule
