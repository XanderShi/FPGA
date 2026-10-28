//======================================================================
//  frame_store.v
//  DDR3 帧存储 + 100 帧环形回放 + 冻结，显示端按行取数。
//
//  存储格式 (每槽 4MiB, 4MiB 对齐):
//    1280*720 个 32bit 像素: {sop, eop, 6'h0, median_gray[7:0], RGB555+edge}
//    [15:0] = RGB555 + 二值边缘(bit0), [23:16] = 中值灰度,
//    [31]/[30] = 帧首/帧尾像素标志(只给写侧定位帧边界用)
//
//  槽分配:
//    slot 0 .. N_RING-1           : 历史环, 写满覆盖最早一帧
//    slot N_RING .. +N_SCRATCH-1  : 冻结/回放期间左屏实时画面, 三缓冲轮换
//
//  写侧 (wclk): 摄像头像素 -> 32bit -> W0_FIFO_32 (32in/128out) -> AXI 写
//  读侧 (pclk): 每行提前一行发取数请求, AXI 读到双 bank 行缓存(BRAM),
//               显示端只读行缓存, DDR 读延迟不会造成 FIFO 欠载。
//
//  显示模式:
//    mode 0 = 实时全屏: 一行取 1 个源, 1280 像素
//    mode 1 = 左实时 / 右冻结: 两个源各取一行, 2x2 抽样成 640x360, 上下黑边
//    mode 2 = 左实时 / 右历史回放: 同上, 右源换成 replay_slot
//
//  槽号/模式在 axi_clk 域产生, 经 toggle 握手搬到 pclk 域, 在帧首锁存。
//======================================================================
`timescale 1ns/1ps

module frame_store #(
	parameter integer H_ACTIVE   = 1280,
	parameter integer V_ACTIVE   = 720,
	parameter integer N_RING     = 100,
	parameter integer N_SCRATCH  = 3,
	parameter integer SLOT_AW    = 22,			// 4MiB / slot
	parameter integer W_BURST    = 128,			// AXI 写突发拍数(128bit/拍)
	parameter integer R_BURST    = 128,			// AXI 读最大突发(2048B, 由 4KB 对齐逻辑切分)
	parameter integer V_ACTIVE_START = 25		// lcd vcnt 中第一个有效行的位置(V_SYNC+V_BACK)
)(
	////////////////////////////////////////////////////////////////
	// AXI4 write
	output wire [3:0]   axi_awid,
	output reg  [31:0]  axi_awaddr,
	output wire [7:0]   axi_awlen,
	output wire [2:0]   axi_awsize,
	output wire [1:0]   axi_awburst,
	output wire         axi_awlock,
	output wire [3:0]   axi_awcache,
	output wire [2:0]   axi_awprot,
	output wire [3:0]   axi_awqos,
	output reg          axi_awvalid,
	input  wire         axi_awready,

	output wire [127:0] axi_wdata,
	output wire [15:0]  axi_wstrb,
	output wire         axi_wlast,
	output reg          axi_wvalid,
	input  wire         axi_wready,

	input  wire [3:0]   axi_bid,
	input  wire [1:0]   axi_bresp,
	input  wire         axi_bvalid,
	output wire         axi_bready,

	////////////////////////////////////////////////////////////////
	// AXI4 read
	output wire [3:0]   axi_arid,
	output reg  [31:0]  axi_araddr,
	output reg  [7:0]   axi_arlen,
	output wire [2:0]   axi_arsize,
	output wire [1:0]   axi_arburst,
	output wire         axi_arlock,
	output wire [3:0]   axi_arcache,
	output wire [2:0]   axi_arprot,
	output wire [3:0]   axi_arqos,
	output reg          axi_arvalid,
	input  wire         axi_arready,

	input  wire [3:0]   axi_rid,
	input  wire [127:0] axi_rdata,
	input  wire [1:0]   axi_rresp,
	input  wire         axi_rlast,
	input  wire         axi_rvalid,
	output reg          axi_rready,

	////////////////////////////////////////////////////////////////
	input  wire         axi_clk,
	input  wire         axi_reset,
	input  wire         ddr_ready,		// DDR 校准完成

	////////////////////////////////////////////////////////////////
	// 写侧: 摄像头像素域
	input  wire         wclk,
	input  wire         wrst,
	input  wire         wvalid,
	input  wire         wsop,			// 帧首像素
	input  wire         weop,			// 帧尾像素
	input  wire [15:0]  wraw,			// RGB555 + edge
	input  wire [7:0]   wgray,			// 中值滤波灰度

	////////////////////////////////////////////////////////////////
	// 控制 (axi_clk 域, 与 sobel_ctrl 同域)
	input  wire [1:0]   ctrl_mode,		// 0=实时 1=冻结 2=回放
	input  wire         freeze_enter,	// 进入冻结(单周期)
	input  wire [6:0]   freeze_slot_in,	// 按键按下沿记下的槽号
	input  wire         replay_enter,	// 进入回放(单周期)
	input  wire         step_prev,		// 回放上一帧
	input  wire         step_next,		// 回放下一帧
	output reg  [6:0]   live_slot_o,	// 最近一次提交的槽(环或 scratch)
	output reg  [6:0]   freeze_slot_o,
	output reg  [6:0]   replay_slot_o,
	output reg  [6:0]   ring_count_o,
	output reg          live_valid_o,	// 至少有一帧完整提交
	output reg          frame_commit_o,
	output wire         underrun_o,		// 行取数赶不上显示(粘滞)

	////////////////////////////////////////////////////////////////
	// 显示侧: 像素时钟域
	input  wire         pclk,
	input  wire         prst,
	input  wire         lcd_line_start,	// hcnt==0, 一拍
	input  wire         lcd_frame_start,// vcnt==0 && hcnt==0, 一拍
	input  wire [11:0]  lcd_vcnt,
	input  wire         lcd_request,
	input  wire [11:0]  lcd_xpos,
	output wire [15:0]  pix_l,			// 左/实时: RGB555+edge
	output wire [15:0]  pix_r,			// 右: 原始 RGB555+edge (冻结/回放彩色对比)
	output wire         pix_valid,		// 本行数据有效
	output wire         pix_split		// 1=左右对比
);

//----------------------------------------------------------------------
// 派生常量
//----------------------------------------------------------------------
localparam integer ROW_BYTES    = H_ACTIVE * 4;
localparam integer FRAME_BYTES  = ROW_BYTES * V_ACTIVE;
localparam integer W_BURST_BYT  = W_BURST * 16;
localparam integer LB_WORDS     = ROW_BYTES / 16;		// 每行 128bit 字数
localparam integer FRAME_BURSTS = FRAME_BYTES / W_BURST_BYT;
localparam integer TILE_W       = H_ACTIVE / 2;
localparam integer SPLIT_H      = V_ACTIVE / 2;
localparam integer SPLIT_Y0     = (V_ACTIVE - SPLIT_H) / 2;
localparam integer SLOT_LAST    = N_RING + N_SCRATCH - 1;

localparam [9:0]   LB_WORDS_C   = LB_WORDS[9:0];
localparam [6:0]   RING_LAST_C  = N_RING[6:0] - 7'd1;
localparam [6:0]   SLOT_LAST_C  = SLOT_LAST[6:0];
localparam [11:0]  VSTART_C     = V_ACTIVE_START[11:0];
localparam [11:0]  VACT_C       = V_ACTIVE[11:0];
localparam [11:0]  SY0_C        = SPLIT_Y0[11:0];
localparam [11:0]  SH_C         = SPLIT_H[11:0];
localparam [11:0]  TILEW_C      = TILE_W[11:0];

//----------------------------------------------------------------------
// AXI 常量
//----------------------------------------------------------------------
assign axi_awid    = 4'd0;
assign axi_awlen   = W_BURST[7:0] - 8'd1;
assign axi_awsize  = 3'd4;
assign axi_awburst = 2'd1;
assign axi_awlock  = 1'b0;
assign axi_awcache = 4'd0;
assign axi_awprot  = 3'd0;
assign axi_awqos   = 4'd0;
assign axi_bready  = 1'b1;
assign axi_wstrb   = 16'hFFFF;

assign axi_arid    = 4'd0;
assign axi_arsize  = 3'd4;
assign axi_arburst = 2'd1;
assign axi_arlock  = 1'b0;
assign axi_arcache = 4'd0;
assign axi_arprot  = 3'd0;
assign axi_arqos   = 4'd0;

//======================================================================
//  写侧: 摄像头像素 -> 32bit -> 异步 FIFO (32in / 128out)
//======================================================================
localparam [1:0] W_IDLE  = 2'd0;
localparam [1:0] W_DATA  = 2'd1;
localparam [1:0] W_BWAIT = 2'd2;

reg  [1:0]  wstate;
reg         w_aligned;

wire [31:0]  wpack      = {wsop, weop, 6'h00, wgray, wraw};
wire         wfifo_rst  = wrst | axi_reset;
wire [127:0] wfifo_rdata;
wire         wfifo_empty;
wire [9:0]   wfifo_rdcnt;
// 与 W 握手同拍弹出 FIFO; 丢弃阶段则逐拍弹出直到帧首
wire         wfifo_ren = (wstate == W_DATA) ? (axi_wvalid && axi_wready)
                      : ((wstate == W_IDLE) && !w_aligned && !wfifo_empty && !wfifo_rdata[127]);

W0_FIFO_32 u_wfifo (
	.prog_full_o     (),
	.full_o          (),
	.empty_o         (wfifo_empty),
	.prog_empty_o    (),
	.wr_clk_i        (wclk),
	.rd_clk_i        (axi_clk),
	.wr_en_i         (wvalid),
	.rd_en_i         (wfifo_ren),
	.wdata           (wpack),
	.rst_busy        (),
	.rdata           (wfifo_rdata),
	.a_rst_i         (wfifo_rst),
	.wr_datacount_o  (),
	.rd_datacount_o  (wfifo_rdcnt),
	.underflow_o     (),
	.overflow_o      ()
);

//----------------------------------------------------------------------
// 写侧控制 (axi_clk)
//----------------------------------------------------------------------
reg  [7:0]  wbeat;
reg  [10:0] wb_cnt;
reg  [21:0] w_off;
reg  [6:0]  w_target;
reg         w_is_ring;
reg  [15:0] wb_wait_cnt;
reg         frame_len_err;

assign axi_wdata = wfifo_rdata;
assign axi_wlast = (wstate == W_DATA) && (wbeat == (W_BURST[7:0] - 8'd1));

//----------------------------------------------------------------------
// 槽 / 环形指针
//----------------------------------------------------------------------
reg  [6:0] ring_wr_slot;
reg  [6:0] scratch_wr_slot;
wire [7:0] oldest_sum  = {1'b0, ring_wr_slot} + N_RING[7:0] - {1'b0, ring_count_o};
wire [6:0] oldest_slot = (oldest_sum >= N_RING[7:0]) ? (oldest_sum[6:0] - N_RING[6:0])
                                                     : oldest_sum[6:0];
wire [6:0] newest_slot = (ring_wr_slot == 7'd0) ? RING_LAST_C : (ring_wr_slot - 7'd1);
wire [6:0] next_wr_slot = (ctrl_mode == 2'd0) ? ring_wr_slot : scratch_wr_slot;

//----------------------------------------------------------------------
// 写状态机
//----------------------------------------------------------------------
always @(posedge axi_clk or posedge axi_reset) begin
	if (axi_reset) begin
		wstate         <= W_IDLE;
		w_aligned      <= 1'b0;
		wbeat          <= 8'd0;
		wb_cnt         <= 11'd0;
		w_off          <= 22'd0;
		w_target       <= 7'd0;
		w_is_ring      <= 1'b1;
		wb_wait_cnt    <= 16'd0;
		frame_len_err  <= 1'b0;
		axi_awvalid    <= 1'b0;
		axi_wvalid     <= 1'b0;
		live_slot_o    <= 7'd0;
		live_valid_o   <= 1'b0;
		frame_commit_o <= 1'b0;
		ring_wr_slot   <= 7'd0;
		scratch_wr_slot<= N_RING[6:0];
		ring_count_o   <= 7'd0;
	end else begin
		frame_commit_o <= 1'b0;

		// AW 握手后必须撤销, 否则会在下一 burst 被当成同一地址的重复写命令
		if (axi_awvalid && axi_awready)
			axi_awvalid <= 1'b0;

		case (wstate)
			W_IDLE: begin
				if (!w_aligned) begin
					// 丢掉上电时帧中间的残留数据, 直到遇到帧首标志
					if (!wfifo_empty && wfifo_rdata[127])
						w_aligned <= 1'b1;
				end else if (ddr_ready && (wfifo_rdcnt >= W_BURST[9:0])) begin
					// 帧首标志只在帧的第一个像素上, 恰好落在突发边界
					if (wfifo_rdata[127]) begin
						if (live_valid_o && (w_off != FRAME_BYTES[21:0]))
							frame_len_err <= 1'b1;
						w_target  <= next_wr_slot;
						w_is_ring <= (ctrl_mode == 2'd0);
						w_off     <= 22'd0;
						wb_cnt    <= 11'd0;
						// 帧首突发要从新槽的 0 偏移开始, 不能用上一帧的 w_target/w_off
						axi_awaddr <= ({25'd0, next_wr_slot} << SLOT_AW);
					end else begin
						axi_awaddr <= ({25'd0, w_target} << SLOT_AW) + {10'd0, w_off};
					end
					axi_awvalid <= 1'b1;
					axi_wvalid  <= 1'b1;
					wbeat       <= 8'd0;
					wb_wait_cnt <= 16'd0;
					wstate      <= W_DATA;
				end
			end

			W_DATA: begin
				if (axi_wvalid && axi_wready) begin
					if (wbeat == (W_BURST[7:0] - 8'd1)) begin
						wbeat      <= 8'd0;
						axi_wvalid <= 1'b0;
						wstate     <= W_BWAIT;
					end else begin
						wbeat <= wbeat + 8'd1;
					end
				end
			end

			W_BWAIT: begin
				if (wb_wait_cnt != 16'hFFFF)
					wb_wait_cnt <= wb_wait_cnt + 16'd1;

				if (axi_bvalid) begin
					w_off       <= w_off + W_BURST_BYT[21:0];
					wb_wait_cnt <= 16'd0;
					if (wb_cnt == (FRAME_BURSTS[10:0] - 11'd1)) begin
						// 本帧最后一个写响应: 发布这一帧
						live_slot_o    <= w_target;
						live_valid_o   <= 1'b1;
						frame_commit_o <= 1'b1;
						if (w_is_ring) begin
							if (ring_count_o < N_RING[6:0])
								ring_count_o <= ring_count_o + 7'd1;
							ring_wr_slot <= (w_target == RING_LAST_C) ? 7'd0 : (w_target + 7'd1);
						end else begin
							scratch_wr_slot <= (w_target == SLOT_LAST_C) ? N_RING[6:0]
							                                             : (w_target + 7'd1);
						end
						wb_cnt <= 11'd0;
					end else begin
						wb_cnt <= wb_cnt + 11'd1;
					end
					wstate <= W_IDLE;
				end
			end

			default: wstate <= W_IDLE;
		endcase
	end
end

//----------------------------------------------------------------------
// 冻结 / 回放槽 (axi_clk)
//----------------------------------------------------------------------
always @(posedge axi_clk or posedge axi_reset) begin
	if (axi_reset) begin
		freeze_slot_o <= 7'd0;
		replay_slot_o <= 7'd0;
	end else begin
		if (freeze_enter)
			freeze_slot_o <= freeze_slot_in;

		if (replay_enter)
			replay_slot_o <= newest_slot;

		if (step_prev && (replay_slot_o != oldest_slot))
			replay_slot_o <= (replay_slot_o == 7'd0) ? RING_LAST_C : (replay_slot_o - 7'd1);

		if (step_next && (replay_slot_o != newest_slot))
			replay_slot_o <= (replay_slot_o == RING_LAST_C) ? 7'd0 : (replay_slot_o + 7'd1);
	end
end

//======================================================================
//  显示上下文跨时钟域: axi_clk -> pclk (toggle + 稳定数据)
//======================================================================
reg  [1:0]  ctx_mode_a;
reg  [6:0]  ctx_live_a, ctx_frz_a, ctx_rep_a;
reg         ctx_tog_a;
reg         live_valid_s1;

always @(posedge axi_clk or posedge axi_reset) begin
	if (axi_reset) begin
		ctx_mode_a    <= 2'd0;
		ctx_live_a    <= 7'd0;
		ctx_frz_a     <= 7'd0;
		ctx_rep_a     <= 7'd0;
		ctx_tog_a     <= 1'b0;
		live_valid_s1 <= 1'b0;
	end else begin
		live_valid_s1 <= live_valid_o;
		if ((ctx_mode_a != ctrl_mode) || (ctx_live_a != live_slot_o) ||
		    (ctx_frz_a != freeze_slot_o) || (ctx_rep_a != replay_slot_o)) begin
			ctx_mode_a <= ctrl_mode;
			ctx_live_a <= live_slot_o;
			ctx_frz_a  <= freeze_slot_o;
			ctx_rep_a  <= replay_slot_o;
			ctx_tog_a  <= ~ctx_tog_a;
		end
	end
end

reg [2:0] ctx_tog_s;
wire      ctx_evt = ctx_tog_s[2] ^ ctx_tog_s[1];

reg [1:0] ctx_mode_p;
reg [6:0] ctx_live_p, ctx_frz_p, ctx_rep_p;
reg [1:0] live_valid_p;
reg       ack_tog_a, ack_bank_a;		// AXI 读完成应答 (axi 域)
reg [2:0] ack_s;
wire      ack_evt = ack_s[2] ^ ack_s[1];
reg       ack_bank_s1, ack_bank_p;

always @(posedge pclk or posedge prst) begin
	if (prst) begin
		ctx_tog_s    <= 3'd0;
		ctx_mode_p   <= 2'd0;
		ctx_live_p   <= 7'd0;
		ctx_frz_p    <= 7'd0;
		ctx_rep_p    <= 7'd0;
		live_valid_p <= 2'd0;
		ack_s        <= 3'd0;
		ack_bank_s1  <= 1'b0;
		ack_bank_p   <= 1'b0;
	end else begin
		ctx_tog_s    <= {ctx_tog_s[1:0], ctx_tog_a};
		live_valid_p <= {live_valid_p[0], live_valid_s1};
		ack_s        <= {ack_s[1:0], ack_tog_a};
		ack_bank_s1  <= ack_bank_a;
		ack_bank_p   <= ack_bank_s1;
		if (ctx_evt) begin
			ctx_mode_p <= ctx_mode_a;
			ctx_live_p <= ctx_live_a;
			ctx_frz_p  <= ctx_frz_a;
			ctx_rep_p  <= ctx_rep_a;
		end
	end
end

//======================================================================
//  取数请求 (pclk) + 行缓存读
//======================================================================
reg  [1:0]  act_mode;
reg  [6:0]  act_live, act_frz, act_rep;
reg         ls_d;			// line_start 延迟一拍(等 act_* 更新)
reg         line_ok;
reg         line_ready;
reg         rd_bank_p;
reg  [127:0] wc_l, wc_r;
reg  [127:0] lbq_l, lbq_r;
reg         req_busy;
reg         req_tog_a;
reg  [11:0] desc_src_y;
reg  [6:0]  desc_slot_l, desc_slot_r;
reg         desc_bank, desc_split;
reg  [1:0]  bank_ready;
reg  [15:0] underrun_cnt;

// 当前显示的组/tile 与行缓存读地址 (组合)
wire grp_first_l = ((act_mode == 2'd0) && (lcd_xpos[1:0] == 2'd0))
                || ((act_mode != 2'd0) && (lcd_xpos < TILEW_C) && (lcd_xpos[0] == 1'b0));
wire grp_first_r = (act_mode != 2'd0) && (lcd_xpos >= TILEW_C) && (lcd_xpos[0] == 1'b0);
wire grp_last_l  = ((act_mode == 2'd0) && (lcd_xpos[1:0] == 2'd3))
                || ((act_mode != 2'd0) && (lcd_xpos < TILEW_C) && (lcd_xpos[0] == 1'b1));
wire grp_last_r  = (act_mode != 2'd0) && (lcd_xpos >= TILEW_C) && (lcd_xpos[0] == 1'b1);

wire [11:0] xpos_r = lcd_xpos - TILEW_C;		// 右 tile 内坐标(仅 x>=TILE_W 有效)
wire [8:0]  word_l = (act_mode == 2'd0) ? lcd_xpos[11:2] : lcd_xpos[11:1];
wire [8:0]  word_r = xpos_r[11:1];
wire [9:0]  next_l = {1'b0, word_l} + 10'd1;
wire [9:0]  next_r = {1'b0, word_r} + 10'd1;

wire [8:0]  lb_addr_l = ((act_mode == 2'd0) || (lcd_xpos < TILEW_C))
                      ? (grp_last_l && (next_l < LB_WORDS_C) ? next_l[8:0] : word_l)
                      : 9'd0;
wire [8:0]  lb_addr_r = ((act_mode != 2'd0) && (lcd_xpos >= TILEW_C))
                      ? (grp_last_r && (next_r < LB_WORDS_C) ? next_r[8:0] : word_r)
                      : 9'd0;

wire [9:0] lb_rd_idx_l = rd_bank_p ? (LB_WORDS_C + {1'b0, lb_addr_l}) : {1'b0, lb_addr_l};
wire [9:0] lb_rd_idx_r = rd_bank_p ? (LB_WORDS_C + {1'b0, lb_addr_r}) : {1'b0, lb_addr_r};

always @(posedge pclk or posedge prst) begin
	if (prst) begin
		act_mode <= 2'd0; act_live <= 7'd0; act_frz <= 7'd0; act_rep <= 7'd0;
		ls_d <= 1'b0;
		line_ok <= 1'b0; line_ready <= 1'b0; rd_bank_p <= 1'b0;
		wc_l <= 128'd0; wc_r <= 128'd0;
		req_busy <= 1'b0; req_tog_a <= 1'b0;
		desc_src_y <= 12'd0; desc_slot_l <= 7'd0; desc_slot_r <= 7'd0;
		desc_bank <= 1'b0; desc_split <= 1'b0;
		bank_ready <= 2'b00;
		underrun_cnt <= 16'd0;
	end else begin
		ls_d <= lcd_line_start;

		//---- 取数完成应答 ----
		if (ack_evt) begin
			req_busy <= 1'b0;
			bank_ready[ack_bank_p] <= 1'b1;
		end

		//---- 帧首锁存显示上下文, 欠载标志按帧清除 ----
		if (lcd_frame_start) begin
			act_mode <= ctx_mode_p;
			act_live <= ctx_live_p;
			act_frz  <= ctx_frz_p;
			act_rep  <= ctx_rep_p;
			underrun_cnt <= 16'd0;
		end

		//---- 行首: 换 bank / 判断本行有效 / 复位行内读指针 ----
		if (ls_d) begin
			rd_bank_p  <= ~lcd_vcnt[0];
			line_ready <= bank_ready[~lcd_vcnt[0]];

			if (act_mode == 2'd0) begin
				line_ok <= (lcd_vcnt >= VSTART_C) && (lcd_vcnt < (VSTART_C + VACT_C));
			end else begin
				line_ok <= (lcd_vcnt >= (VSTART_C + SY0_C)) &&
				           (lcd_vcnt <  (VSTART_C + SY0_C + SH_C));
			end

			// 本行该有数据但没取回来 -> 记欠载
			if (live_valid_p[1]) begin
				if ((act_mode == 2'd0) &&
				    (lcd_vcnt >= VSTART_C) && (lcd_vcnt < (VSTART_C + VACT_C)) &&
				    !bank_ready[~lcd_vcnt[0]])
					underrun_cnt <= underrun_cnt + 16'd1;
				if ((act_mode != 2'd0) &&
				    (lcd_vcnt >= (VSTART_C + SY0_C)) &&
				    (lcd_vcnt <  (VSTART_C + SY0_C + SH_C)) &&
				    !bank_ready[~lcd_vcnt[0]])
					underrun_cnt <= underrun_cnt + 16'd1;
			end
		end

		//---- 发下一行取数请求 ----
		if (ls_d) begin
			if (act_mode == 2'd0) begin
				if (lcd_vcnt == 12'd1) begin
					// 帧同步期间预取第 0 行
					if (!req_busy && live_valid_p[1]) begin
						desc_src_y  <= 12'd0;
						desc_slot_l <= act_live;
						desc_slot_r <= act_live;
						desc_bank   <= 1'b0;
						desc_split  <= 1'b0;
						req_tog_a   <= ~req_tog_a;
						req_busy    <= 1'b1;
						bank_ready[1'b0] <= 1'b0;
					end else if (live_valid_p[1]) begin
						underrun_cnt <= underrun_cnt + 16'd1;
					end
				end else if ((lcd_vcnt >= VSTART_C) &&
				             (lcd_vcnt <  (VSTART_C + VACT_C - 12'd1))) begin
					if (!req_busy && live_valid_p[1]) begin
						desc_src_y  <= lcd_vcnt - VSTART_C + 12'd1;
						desc_slot_l <= act_live;
						desc_slot_r <= act_live;
						desc_bank   <= lcd_vcnt[0];
						desc_split  <= 1'b0;
						req_tog_a   <= ~req_tog_a;
						req_busy    <= 1'b1;
						bank_ready[lcd_vcnt[0]] <= 1'b0;
					end else if (live_valid_p[1]) begin
						underrun_cnt <= underrun_cnt + 16'd1;
					end
				end
			end else begin
				if ((lcd_vcnt >= (VSTART_C + SY0_C - 12'd1)) &&
				    (lcd_vcnt <  (VSTART_C + SY0_C + SH_C - 12'd1))) begin
					if (!req_busy && live_valid_p[1]) begin
						desc_src_y  <= (lcd_vcnt - VSTART_C - SY0_C + 12'd1) << 1;
						desc_slot_l <= act_live;
						desc_slot_r <= (act_mode == 2'd1) ? act_frz : act_rep;
						desc_bank   <= lcd_vcnt[0];
						desc_split  <= 1'b1;
						req_tog_a   <= ~req_tog_a;
						req_busy    <= 1'b1;
						bank_ready[lcd_vcnt[0]] <= 1'b0;
					end else if (live_valid_p[1]) begin
						underrun_cnt <= underrun_cnt + 16'd1;
					end
				end
			end
		end

		//---- 行内像素: 每 4 像素(live) / 2 像素(split) 换一个 128bit 字 ----
		//  组首把刚取回的字装进 wc_l/wc_r; 组内其余像素用寄存器。
		//  行缓存地址是组合的: 组最后一拍就提前指到下一字, 读数据正好在
		//  下一组第一拍准备好(BRAM 一拍读延迟)。
		if (lcd_request) begin
			if (grp_first_l)
				wc_l <= lbq_l;
			if (grp_first_r)
				wc_r <= lbq_r;
		end
	end
end

// 行缓存: 真双口, axi_clk 写 / pclk 读  (index = bank*LB_WORDS + word)
reg [127:0] lb0 [0:2*LB_WORDS-1];	// 左/实时
reg [127:0] lb1 [0:2*LB_WORDS-1];	// 右

always @(posedge pclk) begin
	lbq_l <= lb0[lb_rd_idx_l];
	lbq_r <= lb1[lb_rd_idx_r];
end

// 当前像素字: 组首用刚取回的字, 组内其余像素用寄存器
wire [127:0] cur_l = grp_first_l ? lbq_l : wc_l;
wire [127:0] cur_r = grp_first_r ? lbq_r : wc_r;

wire [1:0] sub = (act_mode == 2'd0) ? lcd_xpos[1:0] : {lcd_xpos[0], 1'b0};

// Efinity FIFO ENDIANESS=0(大端): 32->128 时第一个像素在 [127:96]
wire [15:0] raw16_l = (sub == 2'd0) ? cur_l[111:96] :
                      (sub == 2'd1) ? cur_l[79:64]  :
                      (sub == 2'd2) ? cur_l[47:32]  : cur_l[15:0];
wire [15:0] raw16_r = (sub == 2'd0) ? cur_r[111:96] :
                      (sub == 2'd1) ? cur_r[79:64]  :
                      (sub == 2'd2) ? cur_r[47:32]  : cur_r[15:0];

assign pix_l     = raw16_l;
assign pix_r     = raw16_r;
assign pix_valid = live_valid_p[1] && line_ok && bank_ready[rd_bank_p];
assign pix_split = (act_mode != 2'd0);

//======================================================================
//  AXI 读: 按行取数
//  单 outstanding; 每行按 4KB 边界切成不超过 128 拍(2048B)的突发,
//  1280 宽一行 5120B 通常 3 个突发(128/128/64 或 128/64/128),
//  比 5x64 拍少 2 次 AR/读延迟, 给行缓存留更大余量。
//======================================================================
localparam [1:0] R_IDLE = 2'd0;
localparam [1:0] R_ACT  = 2'd1;

reg  [1:0]  rstate;
reg  [1:0]  cur_tile;			// 0=左/实时  1=右(对比)
reg  [12:0] rd_off;				// 行内字节偏移
reg  [9:0]  wr_beat;			// 行内 128bit 字数
reg         ar_need;
reg  [11:0] rd_src_y;
reg  [6:0]  rd_slot_l, rd_slot_r;
reg         wr_bank, rd_split;
reg  [2:0]  req_s;
wire        req_evt = req_s[2] ^ req_s[1];

wire [31:0] rd_row_base_l = ({25'd0, rd_slot_l} << SLOT_AW) +
                            ({20'd0, rd_src_y} * ROW_BYTES[15:0]);
wire [31:0] rd_row_base_r = ({25'd0, rd_slot_r} << SLOT_AW) +
                            ({20'd0, rd_src_y} * ROW_BYTES[15:0]);
wire [31:0] rd_cur_base = cur_tile ? rd_row_base_r : rd_row_base_l;
wire [31:0] rd_cur_addr = rd_cur_base + {19'd0, rd_off};
wire [31:0] rd_rem      = ROW_BYTES[31:0] - {19'd0, rd_off};
wire [31:0] rd_to4k     = 32'd4096 - (rd_cur_addr & 32'h0000_0FFF);
wire [31:0] rd_len_b    = (rd_rem < rd_to4k)
                        ? ((rd_rem < 32'd2048) ? rd_rem : 32'd2048)
                        : ((rd_to4k < 32'd2048) ? rd_to4k : 32'd2048);
wire [7:0]  rd_len_beats= rd_len_b[11:4];		// 字节/16, 1..128
wire [7:0]  rd_ar_len   = rd_len_beats - 8'd1;

wire        r_hs   = axi_rvalid & axi_rready;
wire        lb_we0 = r_hs & (cur_tile == 2'd0);
wire        lb_we1 = r_hs & (cur_tile == 2'd1);
wire [9:0]  lb_wa  = wr_beat;
wire [9:0]  lb_widx0 = wr_bank ? (LB_WORDS_C + lb_wa) : lb_wa;
wire [9:0]  lb_widx1 = wr_bank ? (LB_WORDS_C + lb_wa) : lb_wa;

always @(posedge axi_clk) begin
	if (lb_we0) lb0[lb_widx0] <= axi_rdata;
	if (lb_we1) lb1[lb_widx1] <= axi_rdata;
end

always @(posedge axi_clk or posedge axi_reset) begin
	if (axi_reset) begin
		rstate      <= R_IDLE;
		cur_tile    <= 2'd0;
		rd_off      <= 13'd0;
		wr_beat     <= 10'd0;
		ar_need     <= 1'b0;
		rd_src_y    <= 12'd0;
		rd_slot_l   <= 7'd0;
		rd_slot_r   <= 7'd0;
		wr_bank     <= 1'b0;
		rd_split    <= 1'b0;
		req_s       <= 3'd0;
		ack_tog_a   <= 1'b0;
		ack_bank_a  <= 1'b0;
		axi_arvalid <= 1'b0;
		axi_araddr  <= 32'd0;
		axi_arlen   <= 8'd0;
		axi_rready  <= 1'b0;
	end else begin
		req_s <= {req_s[1:0], req_tog_a};

		// 新行请求
		if (req_evt) begin
			rd_src_y   <= desc_src_y;
			rd_slot_l  <= desc_slot_l;
			rd_slot_r  <= desc_slot_r;
			wr_bank    <= desc_bank;
			rd_split   <= desc_split;
			cur_tile   <= 2'd0;
			rd_off     <= 13'd0;
			wr_beat    <= 10'd0;
			ar_need    <= 1'b1;
			rstate     <= R_ACT;
			axi_rready <= 1'b1;
		end

		if (rstate == R_ACT) begin
			// 单 outstanding: 上一突发 RLAST 回来后才发下一个 AR
			if (ar_need && !axi_arvalid) begin
				axi_araddr  <= rd_cur_addr;
				axi_arlen   <= rd_ar_len;
				axi_arvalid <= 1'b1;
				ar_need     <= 1'b0;
			end
			if (axi_arvalid && axi_arready)
				axi_arvalid <= 1'b0;

			if (r_hs) begin
				wr_beat <= wr_beat + 10'd1;
				if (axi_rlast) begin
					if (({19'd0, rd_off} + rd_len_b) >= ROW_BYTES[31:0]) begin
						if (rd_split && (cur_tile == 2'd0)) begin
							cur_tile  <= 2'd1;
							rd_off    <= 13'd0;
							wr_beat   <= 10'd0;
							ar_need   <= 1'b1;
						end else begin
							rstate     <= R_IDLE;
							axi_rready <= 1'b0;
							ack_bank_a <= wr_bank;
							ack_tog_a  <= ~ack_tog_a;
						end
					end else begin
						rd_off  <= rd_off + rd_len_b[12:0];
						ar_need <= 1'b1;
					end
				end
			end
		end
	end
end

assign underrun_o = (underrun_cnt != 16'd0);

endmodule
