`timescale 1ns/1ps
//======================================================================
//  tb_frame_store.v
//  frame_store 自测: 小尺寸帧(64x32) + AXI 从机模型 + LCD 行时序
//
//  T1 实时全屏: 写 2 帧, 显示读回第 2 帧, 逐像素比对
//  T2 冻结分屏: 冻结在第 1 帧, 再写一帧到 scratch, 左=实时 右=冻结(中值灰度)
//  T3 回放分屏: 进入回放(最新帧), 翻上一帧, 右图随之变化
//
//  运行: run_sim.bat 里的 tb_frame_store 一步
//======================================================================
module tb_frame_store;

//---- DUT 参数 (默认小尺寸; 可用 vsim -G 覆盖成多突发/行的尺寸) ----
parameter  integer H        = 64;
parameter  integer V        = 32;
parameter  integer LINE_CYC = 200;
parameter  integer SLOT_AW  = 13;			// 8KB / slot
localparam integer N_RING   = 4;
localparam integer N_SCR    = 2;
localparam integer W_BURST  = 128;
localparam integer R_BURST  = 128;		// DUT 最大突发, 从机按 ARLEN 返回
localparam integer VSTART   = 5;

localparam integer FRAME_PIX   = H * V;
localparam integer TILE_W      = H / 2;
localparam integer SPLIT_H     = V / 2;
localparam integer SPLIT_Y0    = (V - SPLIT_H) / 2;
localparam integer H_BACK      = 50;
localparam integer V_TOTAL     = VSTART + V + 5;

integer errors = 0;

//----------------------------------------------------------------------
// 时钟/复位 (wclk/axi_clk/pclk 同源, 简化仿真)
//----------------------------------------------------------------------
reg clk = 0;
always #5 clk = ~clk;

reg rst = 1;
initial begin
	repeat (10) @(posedge clk);
	rst <= 0;
end

//----------------------------------------------------------------------
// 摄像头数据流
//----------------------------------------------------------------------
reg         wvalid = 0;
reg         wsop   = 0;
reg         weop   = 0;
reg  [15:0] wraw   = 0;
reg  [7:0]  wgray  = 0;

reg [15:0] fram_raw [0:7][0:FRAME_PIX-1];
reg [7:0]  fram_gray[0:7][0:FRAME_PIX-1];

integer fr_i;
task send_frame(input integer slot, input [7:0] fid);
begin
	@(negedge clk);
	for (fr_i = 0; fr_i < FRAME_PIX; fr_i = fr_i + 1) begin
		wvalid = 1'b1;
		wsop   = (fr_i == 0);
		weop   = (fr_i == FRAME_PIX-1);
		wraw   = {fid, fr_i[7:0]};
		wgray  = (fr_i * 3 + fid) & 8'hFF;
		fram_raw [slot][fr_i] = wraw;
		fram_gray[slot][fr_i] = wgray;
		@(negedge clk);
	end
	wvalid = 1'b0;
	wsop   = 1'b0;
	weop   = 1'b0;
end
endtask

//----------------------------------------------------------------------
// DUT 控制/状态
//----------------------------------------------------------------------
reg  [1:0] ctrl_mode = 0;
reg        freeze_enter = 0;
reg  [6:0] freeze_slot_in = 0;
reg        replay_enter = 0;
reg        step_prev = 0;
reg        step_next = 0;

wire [6:0] live_slot, freeze_slot, replay_slot, ring_count;
wire       live_valid, frame_commit, underrun;

// AXI 信号
wire [3:0]   awid;   wire [31:0] awaddr; wire [7:0] awlen;
wire [2:0]   awsize; wire [1:0]  awburst; wire awlock;
wire [3:0]   awcache; wire [2:0] awprot; wire [3:0] awqos;
wire         awvalid; wire        awready;
wire [127:0] wdata;  wire [15:0] wstrb; wire wlast, wvalid_axi, wready;
wire [3:0]   bid = 0; wire [1:0] bresp = 0; reg  bvalid; wire bready;
wire [3:0]   arid;   wire [31:0] araddr; wire [7:0] arlen;
wire [2:0]   arsize; wire [1:0]  arburst; wire arlock;
wire [3:0]   arcache; wire [2:0] arprot; wire [3:0] arqos;
wire         arvalid; wire        arready;
wire [127:0] rdata;  wire [1:0]  rresp = 0; wire rlast, rvalid; wire rready;

wire [15:0] pix_l, pix_r;
wire        pix_valid, pix_split;

//----------------------------------------------------------------------
// LCD 行时序 (模拟 1280x720 的计数器结构, 尺寸缩小)
//----------------------------------------------------------------------
reg  [11:0] hc = 0;
reg  [11:0] vc = 0;
always @(posedge clk) begin
	if (hc == LINE_CYC-1) begin
		hc <= 0;
		vc <= (vc == V_TOTAL-1) ? 0 : vc + 1;
	end else hc <= hc + 1;
end

wire lcd_line_start  = (hc == 0);
wire lcd_frame_start = (hc == 0) && (vc == 0);
wire lcd_request     = (hc >= H_BACK) && (hc < H_BACK + H);
wire [11:0] lcd_xpos = lcd_request ? (hc - H_BACK) : 12'd0;

//----------------------------------------------------------------------
// 显示抓取
//----------------------------------------------------------------------
reg        cap = 0;
reg [15:0] dl [0:V-1][0:H-1];
reg [15:0] dr [0:V-1][0:H-1];
reg        dv [0:V-1][0:H-1];
integer    cy, cx;
always @(posedge clk) begin
	if (lcd_request && cap) begin
		cy = vc - VSTART;
		cx = hc - H_BACK;
		if ((cy >= 0) && (cy < V)) begin
			dl[cy][cx] = pix_l;
			dr[cy][cx] = pix_r;
			dv[cy][cx] = pix_valid;
		end
	end
end

task cap_frame;
begin
	@(posedge clk);
	wait (lcd_frame_start);
	cap = 1'b1;
	repeat (V_TOTAL * LINE_CYC) @(posedge clk);
	cap = 1'b0;
end
endtask

task wait_commit;
integer t;
begin
	t = 0;
	while (!frame_commit && (t < 200000)) begin
		@(posedge clk);
		t = t + 1;
	end
	if (!frame_commit) begin
		$display("   [FAIL] commit timeout");
		errors = errors + 1;
	end
	@(posedge clk);
end
endtask

task pulse_freeze(input [6:0] slot);
begin
	ctrl_mode = 1;
	freeze_slot_in = slot;
	freeze_enter = 1;
	@(posedge clk);
	freeze_enter = 0;
	repeat (20) @(posedge clk);
end
endtask

task pulse_replay;
begin
	ctrl_mode = 2;
	replay_enter = 1;
	@(posedge clk);
	replay_enter = 0;
	repeat (20) @(posedge clk);
end
endtask

//----------------------------------------------------------------------
// DUT
//----------------------------------------------------------------------
frame_store #(
	.H_ACTIVE(H), .V_ACTIVE(V),
	.N_RING(N_RING), .N_SCRATCH(N_SCR),
	.SLOT_AW(SLOT_AW),
	.W_BURST(W_BURST), .R_BURST(R_BURST),
	.V_ACTIVE_START(VSTART)
) dut (
	.axi_awid(awid), .axi_awaddr(awaddr), .axi_awlen(awlen),
	.axi_awsize(awsize), .axi_awburst(awburst), .axi_awlock(awlock),
	.axi_awcache(awcache), .axi_awprot(awprot), .axi_awqos(awqos),
	.axi_awvalid(awvalid), .axi_awready(awready),
	.axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wlast(wlast),
	.axi_wvalid(wvalid_axi), .axi_wready(wready),
	.axi_bid(bid), .axi_bresp(bresp), .axi_bvalid(bvalid), .axi_bready(bready),
	.axi_arid(arid), .axi_araddr(araddr), .axi_arlen(arlen),
	.axi_arsize(arsize), .axi_arburst(arburst), .axi_arlock(arlock),
	.axi_arcache(arcache), .axi_arprot(arprot), .axi_arqos(arqos),
	.axi_arvalid(arvalid), .axi_arready(arready),
	.axi_rid(4'd0), .axi_rdata(rdata), .axi_rresp(rresp),
	.axi_rlast(rlast), .axi_rvalid(rvalid), .axi_rready(rready),
	.axi_clk(clk), .axi_reset(rst), .ddr_ready(1'b1),
	.wclk(clk), .wrst(rst),
	.wvalid(wvalid), .wsop(wsop), .weop(weop), .wraw(wraw), .wgray(wgray),
	.ctrl_mode(ctrl_mode),
	.freeze_enter(freeze_enter), .freeze_slot_in(freeze_slot_in),
	.replay_enter(replay_enter), .step_prev(step_prev), .step_next(step_next),
	.live_slot_o(live_slot), .freeze_slot_o(freeze_slot),
	.replay_slot_o(replay_slot), .ring_count_o(ring_count),
	.live_valid_o(live_valid), .frame_commit_o(frame_commit), .underrun_o(underrun),
	.pclk(clk), .prst(rst),
	.lcd_line_start(lcd_line_start), .lcd_frame_start(lcd_frame_start),
	.lcd_vcnt(vc), .lcd_request(lcd_request), .lcd_xpos(lcd_xpos),
	.pix_l(pix_l), .pix_r(pix_r), .pix_valid(pix_valid), .pix_split(pix_split)
);

//----------------------------------------------------------------------
// AXI 从机模型: 写突发进 ddr[], 读突发按 16 拍返回
//----------------------------------------------------------------------
reg [127:0] ddr [0:262143];

// --- 写通道 ---
reg [31:0] wr_addr;
reg [7:0]  wr_cnt;
reg        wr_act = 0;
reg [3:0]  b_dly = 0;
assign awready = !wr_act && (b_dly == 0);
assign wready  = wr_act;

always @(posedge clk) begin
	bvalid <= 1'b0;
	if (!wr_act && awvalid && awready) begin
		wr_act  <= 1'b1;
		wr_addr <= awaddr;
		wr_cnt  <= 8'd0;
	end else if (wr_act) begin
		if (wvalid_axi && wready) begin
			ddr[(wr_addr >> 4) + wr_cnt] <= wdata;
			if (wlast || (wr_cnt == W_BURST-1)) begin
				wr_act <= 1'b0;
				b_dly  <= 4'd3;
			end else begin
				wr_cnt <= wr_cnt + 8'd1;
			end
		end
	end
	if (b_dly != 0) begin
		b_dly <= b_dly - 4'd1;
		if (b_dly == 4'd1)
			bvalid <= 1'b1;
	end
end

// --- 读通道: 4 个 AR 队列, 每次返回 16 拍 ---
reg [31:0] arq     [0:7];
reg [7:0]  arq_len [0:7];
reg [2:0]  arq_wr = 0, arq_rd = 0;
reg [4:0]  arq_cnt = 0;
assign arready = (arq_cnt < 5'd4);

reg  [31:0]  rd_addr;
reg  [7:0]   rd_len  = 0;
reg  [7:0]   rd_beat = 0;
reg  [5:0]   rd_lat  = 0;
reg          rd_act  = 0;
reg  [127:0] rdata_r = 0;

assign rvalid = rd_act && (rd_lat == 0);
assign rlast  = rvalid && (rd_beat == rd_len);
assign rdata  = rdata_r;

always @(posedge clk) begin
	if (arvalid && arready) begin
		arq[arq_wr]     <= araddr;
		arq_len[arq_wr] <= arlen;
		arq_wr <= arq_wr + 3'd1;
		arq_cnt <= arq_cnt + 5'd1;
	end

	if (!rd_act && (arq_cnt != 0)) begin
		rd_act  <= 1'b1;
		rd_addr <= arq[arq_rd];
		rd_len  <= arq_len[arq_rd];
		arq_rd  <= arq_rd + 3'd1;
		arq_cnt <= arq_cnt - 5'd1;
		rd_beat <= 8'd0;
		rd_lat  <= 6'd12;
		rdata_r <= ddr[arq[arq_rd] >> 4];
	end else if (rd_act) begin
		if (rd_lat != 0) begin
			rd_lat <= rd_lat - 6'd1;
		end else if (rvalid && rready) begin
			if (rd_beat == rd_len)
				rd_act <= 1'b0;
			else begin
				rd_beat <= rd_beat + 8'd1;
				rdata_r <= ddr[(rd_addr >> 4) + rd_beat + 8'd1];
			end
		end
	end
end

//----------------------------------------------------------------------
// 检查任务
//----------------------------------------------------------------------
integer ex, ey, exp_l, exp_r, bad;

task check_live(input [6:0] slot);
begin
	bad = 0;
	for (ey = 0; ey < V; ey = ey + 1)
		for (ex = 0; ex < H; ex = ex + 1) begin
			if (!dv[ey][ex]) bad = bad + 1;
			else if (dl[ey][ex] !== fram_raw[slot][ey*H + ex]) begin
				if (bad < 3)
					$display("   [FAIL] live y=%0d x=%0d got=%h exp=%h",
						ey, ex, dl[ey][ex], fram_raw[slot][ey*H + ex]);
				bad = bad + 1;
			end
		end
	if (bad == 0) $display("   [PASS] live full-screen (slot %0d)", slot);
	else begin $display("   [FAIL] live mismatches: %0d", bad); errors = errors + 1; end
end
endtask

task check_split(input [6:0] live_s, input [6:0] right_s);
begin
	bad = 0;
	for (ey = 0; ey < V; ey = ey + 1)
		for (ex = 0; ex < H; ex = ex + 1) begin
			if ((ey < SPLIT_Y0) || (ey >= SPLIT_Y0 + SPLIT_H)) begin
				if (dv[ey][ex]) bad = bad + 1;
			end else if (ex < TILE_W) begin
				exp_l = fram_raw[live_s][(ey-SPLIT_Y0)*2*H + 2*ex];
				if (!dv[ey][ex]) bad = bad + 1;
				else if (dl[ey][ex] !== exp_l[15:0]) begin
					if (bad < 3)
						$display("   [FAIL] split L y=%0d x=%0d got=%h exp=%h",
							ey, ex, dl[ey][ex], exp_l);
					bad = bad + 1;
				end
			end else begin
				exp_r = fram_raw[right_s][(ey-SPLIT_Y0)*2*H + 2*(ex-TILE_W)];
				if (!dv[ey][ex]) bad = bad + 1;
				else if (dr[ey][ex] !== exp_r[15:0]) begin
					if (bad < 3)
						$display("   [FAIL] split R y=%0d x=%0d got=%h exp=%h",
							ey, ex, dr[ey][ex], exp_r);
					bad = bad + 1;
				end
			end
		end
	if (bad == 0) $display("   [PASS] split live=%0d right=%0d", live_s, right_s);
	else begin $display("   [FAIL] split mismatches: %0d", bad); errors = errors + 1; end
end
endtask

//----------------------------------------------------------------------
// 主流程
//----------------------------------------------------------------------
initial begin
	$display("==== tb_frame_store ====");

	repeat (20) @(posedge clk);

	// T1: 实时两帧
	$display("-- T1 live full screen --");
	send_frame(0, 8'h11);
	wait_commit;
	$display("   commit: live_slot=%0d ring_count=%0d", live_slot, ring_count);
	send_frame(1, 8'h22);
	wait_commit;
	$display("   commit: live_slot=%0d ring_count=%0d", live_slot, ring_count);
	repeat (100) @(posedge clk);
	cap_frame;
	check_live(1);

	// T2: 冻结在 slot0, 再写一帧到 scratch
	$display("-- T2 freeze / split --");
	pulse_freeze(7'd0);
	send_frame(N_RING, 8'h33);		// scratch slot 4
	wait_commit;
	$display("   commit: live_slot=%0d freeze=%0d cnt=%0d",
		live_slot, freeze_slot, ring_count);
	repeat (100) @(posedge clk);
	cap_frame;
	check_split(N_RING, 7'd0);

	// T3: 回放, 最新帧 -> 上一帧
	$display("-- T3 replay / step --");
	pulse_replay;
	send_frame(N_RING+1, 8'h44);	// scratch slot 5
	wait_commit;
	repeat (100) @(posedge clk);
	cap_frame;
	check_split(N_RING+1, 7'd1);	// newest ring slot = 1

	@(posedge clk); step_prev = 1;
	@(posedge clk); step_prev = 0;
	repeat (50) @(posedge clk);
	cap_frame;
	check_split(N_RING+1, 7'd0);

	@(posedge clk); step_next = 1;
	@(posedge clk); step_next = 0;
	repeat (50) @(posedge clk);
	cap_frame;
	check_split(N_RING+1, 7'd1);

	// 状态汇总
	if (underrun) begin
		$display("   [FAIL] underrun_o is set");
		errors = errors + 1;
	end else begin
		$display("   [PASS] no underrun");
	end

	if (errors == 0) $display("==== tb_frame_store PASS ====");
	else             $display("==== tb_frame_store FAIL (%0d) ====", errors);
	$finish;
end

// 超时保护
initial begin
	repeat (2000000) @(posedge clk);
	$display("==== tb_frame_store TIMEOUT ====");
	$finish;
end

endmodule

//======================================================================
// 仿真用 W0_FIFO_32: 32bit 写 / 128bit 读, FWFT, 与真实 IP 同端口
//======================================================================
module W0_FIFO_32 (
	output       prog_full_o,
	output       full_o,
	output       empty_o,
	output       prog_empty_o,
	input        wr_clk_i,
	input        rd_clk_i,
	input        wr_en_i,
	input        rd_en_i,
	input  [31:0] wdata,
	output       rst_busy,
	output [127:0] rdata,
	input        a_rst_i,
	output [11:0] wr_datacount_o,
	output [9:0]  rd_datacount_o,
	output        underflow_o,
	output        overflow_o
);
reg [31:0] mem [0:4095];
reg [11:0] wr = 0;
reg [11:0] rd = 0;

assign prog_full_o    = 1'b0;
assign full_o         = 1'b0;
assign empty_o        = (wr == rd);
assign prog_empty_o   = 1'b0;
assign rst_busy       = 1'b0;
assign underflow_o    = 1'b0;
assign overflow_o     = 1'b0;
assign wr_datacount_o = wr - rd;
assign rd_datacount_o = (wr - rd) >> 2;
assign rdata          = {mem[rd], mem[rd+1], mem[rd+2], mem[rd+3]}; // 大端: 第一个像素在高位

always @(posedge wr_clk_i or posedge a_rst_i) begin
	if (a_rst_i) wr <= 12'd0;
	else if (wr_en_i) begin
		mem[wr] <= wdata;
		wr <= wr + 12'd1;
	end
end

always @(posedge rd_clk_i or posedge a_rst_i) begin
	if (a_rst_i) rd <= 12'd0;
	else if (rd_en_i) rd <= rd + 12'd4;
end

endmodule
