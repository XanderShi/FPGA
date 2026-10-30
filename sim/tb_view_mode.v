`timescale 1ns/1ps
//======================================================================
//  tb_view_mode.v   K1+K2 实时画面三模式显示 mux 验证
//
//  与 example_top.v 相同的显示通路 (只取实时分支, pix_valid=1 / pix_split=0):
//    pix_l = {RGB555, Canny边缘} -> lcd_live_col / lcd_live_bin
//    -> view_mode mux -> lcd_driver (真实 1280x720 时序)
//
//  像素源: RGB555 恒为 {5,10,8}, 边缘标志 = (x % 7 == 3), 所以 x=640 是边缘,
//          x=639 / x=641 不是边缘, 正好卡在左右分屏边界上。
//
//  T1 上电/帧1: view_mode=0, 左 640 彩色(非边缘 C, 边缘 FF0000),
//               右 640 二值(非边缘 000000, 边缘 FFFFFF)
//  T2 模式 1: 全屏只有 000000 / FFFFFF
//  T3 模式 2: 全屏彩色, 非边缘 C, 边缘 FF0000
//  T4 模式 2 -> 0 回绕
//  T5 一帧显示到第 200 行时改 view_mode, 当前帧不变, 下一帧才生效(帧起始锁存)
//  T6 四帧从显示画面提取的边缘序列逐像素一致 (同一 pix_l[0])
//======================================================================
`include "lcd_para.v"
module tb_view_mode;
	localparam W = 1280, H = 720;
	localparam [23:0] C_COL = 24'h2D5240;	// RGB555 {5,10,8} 按 d50af88 的映射得到

	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;

	wire        lcd_request, lcd_hs, lcd_vs, lcd_de;
	wire [11:0] lcd_xpos, lcd_ypos;
	wire [7:0]  r, g, b, r2, g2, b2;

	// ---- 帧存储像素模型: pix_l[0] = Canny 边缘 ----
	reg [31:0] rd_idx = 0;
	function [15:0] fb_pix;
		input integer i;
		integer x;
		begin
			x = i % W;
			fb_pix = {5'd5, 5'd10, 5'd8, ((x % 7) == 3)};
		end
	endfunction
	wire [15:0] pix_l = fb_pix(rd_idx);
	always @(posedge clk) begin
		if (lcd_vs == 1'b0) rd_idx <= 0;			// 场同步: 从帧首重新读
		else if (lcd_request) rd_idx <= rd_idx + 1;
	end

	// ---- 与 example_top.v 相同的实时显示逻辑 ----
	wire [23:0] lcd_col_l = {pix_l[15:11], pix_l[13:11],
	                         pix_l[10:6],  pix_l[8:6],
	                         pix_l[5:1],   pix_l[3:1]};
	wire [23:0] lcd_live_col = pix_l[0] ? 24'hFF0000 : lcd_col_l;
	wire [23:0] lcd_live_bin = pix_l[0] ? 24'hFFFFFF : 24'h000000;
	reg  [1:0]  view_mode_pclk = 2'd0;				// 模拟 cfg_toggle 搬过来的值
	reg  [1:0]  view_s1, view_s2, view_mode_px;
	wire        lcd_frame_start;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			view_s1 <= 2'd0;
			view_s2 <= 2'd0;
		end else begin
			view_s1 <= view_mode_pclk;
			view_s2 <= view_s1;
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n)               view_mode_px <= 2'd0;
		else if (lcd_frame_start) view_mode_px <= view_s2;
	wire [23:0] lcd_live = (view_mode_px == 2'd0) ? ((lcd_xpos < 12'd640) ? lcd_live_col : lcd_live_bin) :
	                       (view_mode_px == 2'd1) ? lcd_live_bin : lcd_live_col;
	wire [23:0] lcd_pixel = lcd_live;

	lcd_driver u_lcd (
		.clk(clk), .rst_n(rst_n), .lcd_dclk(), .lcd_blank(), .lcd_sync(),
		.lcd_request(lcd_request), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_en(lcd_de),
		.lcd_rgb({r2,g2,b2,r,g,b}), .lcd_xpos(lcd_xpos), .lcd_ypos(lcd_ypos),
		.lcd_line_start(), .lcd_frame_start(lcd_frame_start), .lcd_vcnt(),
		.lcd_data({lcd_pixel, lcd_pixel})
	);

	// ---- 源图案 (x 方向周期 7, x%7==3 为边缘) ----
	reg src_x_edge [0:W-1];
	integer k;
	initial for (k = 0; k < W; k = k + 1) src_x_edge[k] = ((k % 7) == 3);

	// ---- 逐像素记分板 ----
	integer errors = 0;
	integer frames = 0, px = 0, py = 0;
	integer bad_pix = 0, bad_edge = 0;
	integer b639 = 0, b640 = 0, b641 = 0;			// 分屏边界检查计数
	reg prev_vs = 1, capture = 0;
	reg [1:0] exp_mode = 2'd0;
	reg got_edge, exp_edge, exp_col_half;
	reg [23:0] exp_pix;
	reg ref_edge [0:W*H-1];
	integer idx;

	task check_pixel;
		input integer x, y;
		input [23:0] got;
		begin
			idx    = y*W + x;
			exp_edge = src_x_edge[x];
			case (exp_mode)
				2'd0: begin
					exp_pix = (x < 640) ? (exp_edge ? 24'hFF0000 : C_COL)
					                    : (exp_edge ? 24'hFFFFFF : 24'h000000);
					got_edge = (x < 640) ? (got == 24'hFF0000) : (got == 24'hFFFFFF);
				end
				2'd1: begin
					exp_pix = exp_edge ? 24'hFFFFFF : 24'h000000;
					got_edge = (got == 24'hFFFFFF);
				end
				default: begin
					exp_pix = exp_edge ? 24'hFF0000 : C_COL;
					got_edge = (got == 24'hFF0000);
				end
			endcase
			if (got !== exp_pix) begin
				bad_pix = bad_pix + 1;
				if (bad_pix <= 5)
					$display("  [FAIL] mode=%0d (%0d,%0d): got %06h exp %06h",
					         exp_mode, x, y, got, exp_pix);
			end
			// 边缘序列: 第 1 个采集帧存参考, 后面逐像素比较
			if (frames == 2) ref_edge[idx] = exp_edge;
			else if (got_edge !== ref_edge[idx]) begin
				bad_edge = bad_edge + 1;
				if (bad_edge <= 5)
					$display("  [FAIL] mode=%0d edge seq (%0d,%0d): got %0d exp %0d",
					         exp_mode, x, y, got_edge, ref_edge[idx]);
			end
			// 分屏边界
			if (x == 639) b639 = b639 + 1;
			if (x == 640) b640 = b640 + 1;
			if (x == 641) b641 = b641 + 1;
		end
	endtask

	always @(posedge clk) begin
		prev_vs <= lcd_vs;
		if (lcd_frame_start) exp_mode <= view_mode_pclk;
		if (!prev_vs && lcd_vs) begin			// 场同步结束 = 本帧有效区开始
			frames = frames + 1;
			px = 0; py = 0;
			if (frames >= 2 && frames <= 5)
				$display("-- frame %0d: view_mode=%0d --", frames, exp_mode);
			if (frames == 2) begin
				capture = 1;
			end
			if (frames == 6) begin
				capture = 0;
				finish_check;
			end
		end
		if (capture && lcd_de) begin
			check_pixel(px, py, {r,g,b});
			// 第 2/3/4 帧显示到第 200 行时改模式, 当前帧必须保持旧模式
			if (py == 200 && px == 0) begin
				case (frames)
					2: view_mode_pclk <= 2'd1;
					3: view_mode_pclk <= 2'd2;
					4: view_mode_pclk <= 2'd0;
				endcase
			end
			px = px + 1;
			if (px == W) begin px = 0; py = py + 1; end
		end
	end

	task finish_check;
		begin
			if (bad_pix != 0)  errors = errors + 1;
			if (bad_edge != 0) errors = errors + 1;
			if (b639 == 0 || b640 == 0 || b641 == 0) begin
				errors = errors + 1;
				$display("  [FAIL] split boundary rows not captured: 639=%0d 640=%0d 641=%0d",
				         b639, b640, b641);
			end
			$display("=====================================================");
			$display(" frames checked = %0d (mode 0,1,2,0)", frames - 2);
			$display(" pixel mismatches = %0d, edge-seq mismatches = %0d", bad_pix, bad_edge);
			$display(" split checks: x=639 %0d rows, x=640 %0d rows, x=641 %0d rows",
			         b639, b640, b641);
			if (errors == 0) $display(" RESULT: ALL CHECKS PASSED");
			else             $display(" RESULT: FAILED");
			$display("=====================================================");
			$finish;
		end
	endtask

	initial begin
		repeat (10) @(posedge clk); rst_n = 1;
	end
	initial begin
		repeat (20000000) @(posedge clk);
		$display("==== tb_view_mode TIMEOUT ====");
		$finish;
	end
endmodule
