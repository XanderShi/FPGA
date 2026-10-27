//======================================================================
//  sobel_ctrl.v   按键控制: 阈值 / 算法模式 / 冻结 / 100帧回放
//
//   K1 短按 : 实时/冻结模式 阈值 -8;  回放模式 上一帧
//   K2 短按 : 实时/冻结模式 阈值 +8;  回放模式 下一帧
//   K1 长按(0.8s) : 实时 -> 冻结(画面定格在按下沿那一帧) / 冻结 -> 实时
//                   回放 -> 实时
//   K2 长按(0.8s) : 实时/冻结 -> 回放(从最新一帧开始) / 回放 -> 实时
//   K1+K2 同时按   : 算法模式循环 2(Canny+识别) -> 0(Sobel) -> 1(Canny) -> 2
//
//   按键低有效, 两级同步 + 20ms 消抖
//   长按触发点在按住 0.8s 时; 冻结帧的槽号在"按下沿"就锁存, 所以定格的
//   是按键那一瞬间的帧, 不是 0.8s 后的帧
//======================================================================
module sobel_ctrl #(
	parameter CLK_FREQ      = 96_000_000,
	parameter DEBOUNCE_MS   = 20,
	parameter LONG_MS       = 800,
	parameter [10:0] THR_DEFAULT = 11'd64,
	parameter [10:0] THR_STEP    = 11'd8,
	parameter [10:0] THR_MAX     = 11'd2040,
	parameter [1:0]  MODE_DEFAULT= 2'd2
)(
	input              clk,
	input              rst_n,
	input              key1_n,
	input              key2_n,
	input  [6:0]       live_slot,		// frame_store 最近提交槽
	input              live_valid,
	input              frames_ready,	// 至少有一帧(回放用)
	output reg  [10:0] threshold,
	output reg  [1:0]  mode,			// 算法: 0 Sobel 1 Canny 2 Canny+识别
	output reg         cfg_toggle,
	output reg  [1:0]  disp_mode,		// 显示: 0 实时 1 冻结 2 回放
	output reg         freeze_enter,
	output reg  [6:0]  freeze_slot_in,
	output reg         replay_enter,
	output reg         step_prev,
	output reg         step_next
);

	localparam CNT_DB   = (CLK_FREQ/1000)*DEBOUNCE_MS;
	localparam CNT_LONG = (CLK_FREQ/1000)*LONG_MS;

//----------------------------------------------------------------------
// 两级同步 + 消抖
//----------------------------------------------------------------------
	reg k1_s1,k1_s2,k2_s1,k2_s2;
	always @(posedge clk or negedge rst_n)
		if(!rst_n) begin k1_s1<=1'b1; k1_s2<=1'b1; k2_s1<=1'b1; k2_s2<=1'b1; end
		else begin
			k1_s1<=key1_n; k1_s2<=k1_s1;
			k2_s1<=key2_n; k2_s2<=k2_s1;
		end

	reg        k1_clean,k2_clean;
	reg [20:0] db1_cnt,db2_cnt;
	always @(posedge clk or negedge rst_n)
		if(!rst_n) begin
			k1_clean<=1'b1; k2_clean<=1'b1;
			db1_cnt<=21'd0; db2_cnt<=21'd0;
		end else begin
			if(k1_s2 != k1_clean) begin
				if(db1_cnt >= CNT_DB-1) begin k1_clean<=k1_s2; db1_cnt<=21'd0; end
				else db1_cnt <= db1_cnt + 1'b1;
			end else db1_cnt <= 21'd0;

			if(k2_s2 != k2_clean) begin
				if(db2_cnt >= CNT_DB-1) begin k2_clean<=k2_s2; db2_cnt<=21'd0; end
				else db2_cnt <= db2_cnt + 1'b1;
			end else db2_cnt <= 21'd0;
		end

	wire p1   = ~k1_clean;
	wire p2   = ~k2_clean;
	wire both = p1 & p2;

//----------------------------------------------------------------------
// 组合键 (算法模式)
//----------------------------------------------------------------------
	reg both_d;
	always @(posedge clk or negedge rst_n)
		if(!rst_n) both_d <= 1'b0;
		else       both_d <= both;
	wire combo_hit = both & ~both_d;

//----------------------------------------------------------------------
// 单键: 按下沿 / 松开沿 / 长按 0.8s 一次性触发
//----------------------------------------------------------------------
	reg p1_d, p2_d;
	reg [26:0] hold1, hold2;	// 96MHz*0.8s=76.8M > 2^26, 必须 27 位
	reg long1_done, long2_done;
	reg combo1_seen, combo2_seen;
	reg long1, long2, short1, short2;

	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin
			p1_d<=1'b0; p2_d<=1'b0;
			hold1<=27'd0; hold2<=27'd0;
			long1_done<=1'b0; long2_done<=1'b0;
			combo1_seen<=1'b0; combo2_seen<=1'b0;
			long1<=1'b0; long2<=1'b0; short1<=1'b0; short2<=1'b0;
		end else begin
			p1_d <= p1; p2_d <= p2;
			long1<=1'b0; long2<=1'b0; short1<=1'b0; short2<=1'b0;

			//---- K1 ----
			if(p1 & ~p1_d) begin
				hold1<=27'd0; long1_done<=1'b0; combo1_seen<=1'b0;
			end else if(p1) begin
				if(both) begin
					combo1_seen<=1'b1; hold1<=27'd0;
				end else if(!long1_done && !combo1_seen) begin
					if(hold1 >= CNT_LONG-1) begin
						long1<=1'b1; long1_done<=1'b1;
					end else hold1 <= hold1 + 1'b1;
				end
			end
			if(~p1 & p1_d) begin
				if(!long1_done && !combo1_seen) short1<=1'b1;
			end

			//---- K2 ----
			if(p2 & ~p2_d) begin
				hold2<=27'd0; long2_done<=1'b0; combo2_seen<=1'b0;
			end else if(p2) begin
				if(both) begin
					combo2_seen<=1'b1; hold2<=27'd0;
				end else if(!long2_done && !combo2_seen) begin
					if(hold2 >= CNT_LONG-1) begin
						long2<=1'b1; long2_done<=1'b1;
					end else hold2 <= hold2 + 1'b1;
				end
			end
			if(~p2 & p2_d) begin
				if(!long2_done && !combo2_seen) short2<=1'b1;
			end
		end
	end

//----------------------------------------------------------------------
// 按下沿锁存"当前帧"槽号: 长按 0.8s 后仍冻结这一帧
//----------------------------------------------------------------------
	reg [6:0] press_slot;
	always @(posedge clk or negedge rst_n)
		if(!rst_n) press_slot <= 7'd0;
		else if(p1 & ~p1_d) press_slot <= live_slot;

//----------------------------------------------------------------------
// 阈值
//----------------------------------------------------------------------
	always @(posedge clk or negedge rst_n)
		if(!rst_n) threshold <= THR_DEFAULT;
		else if(short1 && (disp_mode != 2'd2))
			threshold <= (threshold > THR_STEP) ? (threshold - THR_STEP) : 11'd0;
		else if(short2 && (disp_mode != 2'd2))
			threshold <= (threshold < (THR_MAX - THR_STEP)) ? (threshold + THR_STEP) : THR_MAX;

//----------------------------------------------------------------------
// 算法模式 (K1+K2)
//----------------------------------------------------------------------
	always @(posedge clk or negedge rst_n)
		if(!rst_n) mode <= MODE_DEFAULT;
		else if(combo_hit) mode <= (mode==2'd2) ? 2'd0 : (mode + 1'b1);

//----------------------------------------------------------------------
// 显示模式 / 冻结 / 回放
//----------------------------------------------------------------------
	always @(posedge clk or negedge rst_n) begin
		if(!rst_n) begin
			disp_mode       <= 2'd0;
			freeze_enter    <= 1'b0;
			replay_enter    <= 1'b0;
			freeze_slot_in  <= 7'd0;
			step_prev       <= 1'b0;
			step_next       <= 1'b0;
		end else begin
			freeze_enter <= 1'b0;
			replay_enter <= 1'b0;
			step_prev    <= 1'b0;
			step_next    <= 1'b0;

			// K1 长按
			if(long1) begin
				if(disp_mode == 2'd0) begin
					if(live_valid) begin
						disp_mode      <= 2'd1;
						freeze_enter   <= 1'b1;
						freeze_slot_in <= press_slot;
					end
				end else begin
					disp_mode <= 2'd0;		// 冻结/回放 -> 实时
				end
			end

			// K2 长按
			if(long2) begin
				if(disp_mode == 2'd2) begin
					disp_mode <= 2'd0;		// 回放 -> 实时
				end else if(frames_ready) begin
					disp_mode    <= 2'd2;	// 实时/冻结 -> 回放
					replay_enter <= 1'b1;
				end
			end

			// 回放翻帧
			if(short1 && (disp_mode == 2'd2)) step_prev <= 1'b1;
			if(short2 && (disp_mode == 2'd2)) step_next <= 1'b1;
		end
	end

//----------------------------------------------------------------------
// 配置变化标志 (阈值/算法模式 -> 像素时钟域)
//----------------------------------------------------------------------
	reg [10:0] thr_d;
	reg [1:0]  mode_d;
	reg        chg,chg1,chg2,chg3;
	reg [4:0]  pwr_cnt;

	always @(posedge clk or negedge rst_n)
		if(!rst_n) begin
			thr_d<=THR_DEFAULT; mode_d<=MODE_DEFAULT;
			chg<=1'b0; chg1<=1'b0; chg2<=1'b0; chg3<=1'b0;
			pwr_cnt<=5'd0;
		end else begin
			thr_d <= threshold;
			mode_d<= mode;
			chg   <= (thr_d!=threshold) || (mode_d!=mode) || (pwr_cnt==5'd15);
			chg1  <= chg;
			chg2  <= chg1;
			chg3  <= chg2;
			if(pwr_cnt < 5'd31) pwr_cnt <= pwr_cnt + 1'b1;
		end

	always @(posedge clk or negedge rst_n)
		if(!rst_n)        cfg_toggle <= 1'b0;
		else if(chg3)     cfg_toggle <= ~cfg_toggle;

endmodule
