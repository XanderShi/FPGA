`timescale 1ns/1ps
// Reproduce the real producer/consumer rate relationship: camera pixels
// arrive one per wframe_clk while the AXI writer drains one beat per axi_clk.
// Compile together with tb_frame_ring_ctrl.v for the small FIFO models.

module tb_frame_write_stream;

parameter integer H = 1280;
parameter integer V = 4;
localparam integer NPIX = H*V;
localparam integer WB = 128;
localparam [31:0] MED_BYTES = 32'h0020_0000;
localparam integer MED_WORDS = MED_BYTES >> 1;
localparam integer MEM_WORDS = MED_WORDS + NPIX;

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

reg w_sop = 0, w_eop = 0, w_valid = 0;
reg [15:0] w_raw = 0;
reg [7:0] w_gray = 0;
reg [1:0] mode = 0;
reg prev_pulse = 0, next_pulse = 0;

wire [31:0] awaddr;
wire [7:0] awlen;
wire awvalid;
reg awready = 1;
wire [127:0] wdata;
wire [15:0] wstrb;
wire wlast, wvalid;
reg wready = 1;
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
reg arready = 1;
reg [3:0] rid = 0;
reg [127:0] axi_rdata = 0;
reg [1:0] rresp = 0;
reg rlast = 0, rvalid = 0;
wire rready;

wire [15:0] rdata;
wire rdata_valid;
wire [6:0] live_slot, freeze_slot, replay_slot, ring_count, write_slot;
wire write_slot_tog, commit, live_valid_dut;

reg [15:0] mem [0:MEM_WORDS-1];
integer i;
integer beat_word;
integer errors = 0;
integer raw_errors = 0;
integer med_errors = 0;
integer bdelay = 0;
integer aw_count = 0;
reg [31:0] write_addr;
reg [7:0] write_beat = 0;

always @(posedge clk) begin
	if (rst) begin
		bvalid <= 0;
		bdelay <= 0;
	end else begin
		if (awvalid && awready) begin
			write_addr = awaddr;
			write_beat = 0;
			aw_count = aw_count + 1;
		end
		if (wvalid && wready) begin
			if (wlast)
				bdelay <= 2;
			if (wlast)
				write_beat <= 0;
			else
				write_beat <= write_beat + 1'b1;
		end else if (bdelay != 0) begin
			bdelay <= bdelay - 1;
		end
		bvalid <= (bdelay == 1);
	end
end

always @(negedge clk) begin
	if (!rst && wvalid && wready) begin
		for (beat_word=0; beat_word<8; beat_word=beat_word+1)
			mem[(write_addr >> 1) + write_beat*8 + beat_word] <=
				wdata[beat_word*16 +: 16];
	end
end

frame_ring_ctrl #(
	.H_ACTIVE(H),
	.V_ACTIVE(V),
	.N_FRAMES(2),
	.SLOT_BYTES(32'h0040_0000),
	.MED_OFFSET(MED_BYTES),
	.W_BURST(WB),
	.R_BURST(2)
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
	.wframe_clk(clk), .wframe_rst(rst), .wframe_sop(w_sop), .wframe_eop(w_eop),
	.wframe_valid(w_valid), .wframe_raw(w_raw), .wframe_gray(w_gray),
	.rframe_clk(clk), .rframe_rst(rst), .rframe_vsync(1'b0),
	.rframe_data_en(1'b0), .rframe_data(rdata), .rframe_data_valid(rdata_valid),
	.display_mode(mode), .prev_frame(prev_pulse), .next_frame(next_pulse),
	.live_slot(live_slot), .freeze_slot(freeze_slot), .replay_slot(replay_slot),
	.ring_count(ring_count), .write_slot(write_slot),
	.write_slot_toggle(write_slot_tog), .frame_commit(commit),
	.live_valid(live_valid_dut), .read_debug(), .out_data_seen()
);

task check(input integer cond, input [8*72:1] name);
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
	for (i=0; i<MEM_WORDS; i=i+1)
		mem[i] = 16'hDEAD;
	repeat(20) @(posedge clk);
	rst = 0;
	repeat(10) @(posedge clk);

	// No artificial gaps: this is the fastest legal camera-style stream.
	@(negedge clk);
	w_sop = 1;
	w_valid = 1;
	w_raw = 16'h1000;
	w_gray = 8'h80;
	for (i=1; i<NPIX; i=i+1) begin
		@(negedge clk);
		w_sop = 0;
		w_raw = 16'h1000 + i;
		w_gray = 8'h80 + i;
	end
	@(negedge clk);
	w_valid = 0;
	w_eop = 1;
	@(negedge clk);
	w_eop = 0;

	wait(commit);
	repeat(20) @(posedge clk);

	for (i=0; i<NPIX; i=i+1) begin
		if (mem[i] !== (16'h1000 + i[15:0])) begin
			errors = errors + 1;
			raw_errors = raw_errors + 1;
			if (raw_errors <= 4)
				$display("   raw[%0d]=0x%04x expect=0x%04x",
					i, mem[i], 16'h1000 + i[15:0]);
		end
		if (mem[MED_WORDS + i] !== {8'h00, (8'h80 + i[7:0])}) begin
			errors = errors + 1;
			med_errors = med_errors + 1;
			if (med_errors <= 4)
				$display("   med[%0d]=0x%04x expect=0x%04x",
					i, mem[MED_WORDS + i], {8'h00, (8'h80 + i[7:0])});
		end
	end

	$display(" producer pixels=%0d AW bursts=%0d raw_ptr=%0d med_ptr=%0d",
		NPIX, aw_count, dut.raw_ptr, dut.med_ptr);
	$display(" DDR word mismatches=%0d (raw=%0d median=%0d)",
		errors, raw_errors, med_errors);
	check(errors == 0, "streaming camera frame is stored without FIFO underflow corruption");
	check(dut.raw_ptr == NPIX*2, "raw plane advances by exactly one frame");
	check(dut.med_ptr == NPIX*2, "median plane advances by exactly one frame");

	$display("==============================================");
	if (errors == 0)
		$display(" RESULT: ALL CHECKS PASSED");
	else
		$display(" RESULT: WRITE-PATH UNDERFLOW REPRODUCED");
	$finish;
end

initial begin
	#(NPIX*10 + 2_000_000);
	$display(" TIMEOUT state=%0d beat=%0d raw_ptr=%0d med_ptr=%0d",
		dut.wstate, dut.wr_beat, dut.raw_ptr, dut.med_ptr);
	$display(" capture=%0d flush=%0d raw_empty=%0d med_empty=%0d outstanding=%0d",
		dut.capture_active, dut.flush_pending, dut.raw_fifo_empty,
		dut.med_fifo_empty, dut.wr_outstanding);
	$display(" start/end toggles=%0d/%0d edges=%0d/%0d",
		dut.wframe_start_toggle, dut.wframe_end_toggle,
		dut.frame_start_edge, dut.frame_end_edge);
	$finish;
end

endmodule
