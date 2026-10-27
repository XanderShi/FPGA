`timescale 1ns/1ps
// End-to-end writer -> AXI memory model -> display reader check.
// Compile together with tb_frame_ring_ctrl.v (defines the small FIFO models).

module tb_frame_e2e;

localparam integer H = 16;
localparam integer V = 4;
localparam integer NPIX = H*V;

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

reg w_sop=0, w_eop=0, w_valid=0;
reg [15:0] w_raw=0;
reg [7:0]  w_gray=0;
reg [1:0]  mode=0;
reg prev_pulse=0, next_pulse=0;
reg rvsync=0, rd_en=0;

wire [31:0] awaddr;
wire [7:0] awlen;
wire awvalid;
reg awready=1;
wire [127:0] wdata;
wire [15:0] wstrb;
wire wlast, wvalid;
reg wready=1;
wire bready;
reg [3:0] bid=0;
reg [1:0] bresp=0;
reg bvalid=0;

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
reg arready=1;

reg [3:0] rid=0;
reg [127:0] axi_rdata=0;
reg [1:0] rresp=0;
reg rlast=0, rvalid=0;
wire rready;

wire [15:0] rd_data;
wire [6:0] live_slot, freeze_slot, replay_slot, ring_count, write_slot;
wire write_slot_tog, commit, live_valid_dut;

reg [15:0] mem [0:4095];	// 16-bit words, byte-addressable below 8 KiB
integer wp;
integer errors=0;
integer out_count=0;
integer out_idx=0;
integer i;
integer bdelay=0;
reg [31:0] write_addr;
reg [31:0] read_addr;
reg [1:0] read_beat;

frame_ring_ctrl #(
	.H_ACTIVE(H),
	.V_ACTIVE(V),
	.N_FRAMES(4),
	.SLOT_BYTES(32'h0000_1000),
	.MED_OFFSET(32'h0000_0200),
	.W_BURST(1),
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
	.rframe_clk(clk), .rframe_rst(rst), .rframe_vsync(rvsync),
	.rframe_data_en(rd_en), .rframe_data(rd_data), .rframe_data_valid(),
	.display_mode(mode), .prev_frame(prev_pulse), .next_frame(next_pulse),
	.live_slot(live_slot), .freeze_slot(freeze_slot), .replay_slot(replay_slot),
	.ring_count(ring_count), .write_slot(write_slot),
	.write_slot_toggle(write_slot_tog), .frame_commit(commit),
	.live_valid(live_valid_dut), .read_debug(), .out_data_seen()
);

always @(posedge clk) begin
	if (rst) begin
		bvalid <= 0;
		bdelay <= 0;
		rvalid <= 0;
		rlast <= 0;
		read_beat <= 0;
	end else begin
		if (awvalid && awready) begin
			write_addr = awaddr;
		end
		if (wvalid && wready) begin
			for (i=0; i<8; i=i+1)
				mem[(write_addr >> 1) + i] <= wdata[i*16 +: 16];
			bdelay <= 2;
		end else if (bdelay != 0) begin
			bdelay <= bdelay - 1;
		end
		bvalid <= (bdelay == 1);

		if (arvalid && arready && !rvalid) begin
			read_addr = araddr;
			read_beat = 0;
			axi_rdata = {mem[(read_addr>>1)+7],mem[(read_addr>>1)+6],
				mem[(read_addr>>1)+5],mem[(read_addr>>1)+4],
				mem[(read_addr>>1)+3],mem[(read_addr>>1)+2],
				mem[(read_addr>>1)+1],mem[(read_addr>>1)+0]};
			rvalid = 1;
			rlast = 0;
		end else if (rvalid && rready) begin
			if (read_beat == 1) begin
				rvalid <= 0;
				rlast <= 0;
			end else begin
				read_beat = read_beat + 1;
				read_addr = read_addr + 16;
				axi_rdata = {mem[(read_addr>>1)+7],mem[(read_addr>>1)+6],
					mem[(read_addr>>1)+5],mem[(read_addr>>1)+4],
					mem[(read_addr>>1)+3],mem[(read_addr>>1)+2],
					mem[(read_addr>>1)+1],mem[(read_addr>>1)+0]};
				rlast <= 1;
			end
		end
	end
end

initial begin
	wp = 0;
	for (i=0; i<4096; i=i+1)
		mem[i] = 16'hDEAD;
	repeat(20) @(posedge clk);
	rst = 0;
	repeat(10) @(posedge clk);

	@(negedge clk);
	w_sop = 1; w_valid = 1; w_raw = 16'h1000; w_gray = 8'h80;
	for (wp=1; wp<NPIX; wp=wp+1) begin
		@(negedge clk);
		w_sop = 0;
		w_raw = 16'h1000 + wp[15:0];
		w_gray = 8'h80 + wp[7:0];
	end
	@(posedge clk);
	@(negedge clk);
	w_valid = 0;
	w_eop = 1;
	@(negedge clk);
	w_eop = 0;

	wait(commit);
	repeat(20) @(posedge clk);
	rvsync = 1;
	repeat(2) @(posedge clk);
	rvsync = 0;

	// Preload the complete small frame before starting LCD consumption.
	repeat(500) @(posedge clk);
	rd_en = 1;
	for (out_idx=0; out_idx<NPIX; out_idx=out_idx+1) begin
		@(negedge clk);
		if (rd_data !== (16'h1000 + out_idx[15:0])) begin
			if (errors < 8)
				$display("   mismatch[%0d]=0x%04x expect=0x%04x",
					out_idx, rd_data, 16'h1000 + out_idx[15:0]);
			errors = errors + 1;
		end
		@(posedge clk);
	end
	rd_en = 0;
	$display(" e2e read words: %0d / %0d, mismatches: %0d",
		out_idx, NPIX, errors);
	if ((out_idx >= NPIX) && (errors == 0))
		$display(" RESULT: PASS");
	else
		$display(" RESULT: FAIL");
	$finish;
end

endmodule
