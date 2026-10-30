//======================================================================
//  tb_display_overlay.v   显示端叠加层仿真: lcd_driver 真实时序 + FWFT 读FIFO模型
//
//  模拟 example_top.v 的显示通路: DDR 读回的 16bit 打包像素 -> 分屏(左彩色/右二值)
//  -> shape_overlay(多目标包围盒 + 每个框的中文标签) -> lcd_driver。
//
//  第 1 张: 三个目标 (圆 左上 / 矩 中上 / 三角 右中), 三种颜色三个框三个标签
//  第 2 张: target_count = 0, 必须只显示「未识别」, 不能残留任何框或标签
//
//  自动检查:
//    * 每个框的 4 条边正好落在给定坐标上, 且框外 1 像素没有同色像素
//    * 每个标签区域里有足够多的该目标颜色像素 (说明中文标签画出来了)
//    * 空白帧: 全屏没有形状颜色, 「未识别」底板与红色文字都在
//  两张图分别写成 overlay_multi.ppm / overlay_none.ppm, 可用
//  python3 sim/ppm2png.py 转 PNG 目检。
//======================================================================
`timescale 1ns/1ps
`include "lcd_para.v"
module tb_display_overlay;
	localparam W = 1280, H = 720;

	localparam NT = 3;
	localparam GSZ = 32;			// S=2 时每个汉字 32x32
	localparam PAD = 6;
	localparam LBLX = 24, LBLY = 24;

	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;

	wire        lcd_request, lcd_hs, lcd_vs, lcd_de;
	wire [11:0] lcd_xpos, lcd_ypos;
	wire [7:0]  r, g, b, r2, g2, b2;

	// ---- FWFT 读 FIFO 模型: rdata 一直给出队头, rd_en 时出队 ----
	reg  [31:0] rd_idx = 0;
	function [15:0] fb_pix;		// 帧缓存第 i 个像素: {RGB555, 边缘标志}
		input integer i;
		integer x, y;
		begin
			x = i % W; y = i / W;
			// 两种深色棋盘, 都远离三种形状颜色, 便于「没有形状颜色」的判定
			fb_pix = (((x/64) + (y/64)) % 2) ? 16'h2104 : 16'h18C3;
		end
	endfunction
	wire [15:0] lcd_data = fb_pix(rd_idx);
	always @(posedge clk) begin
		if (lcd_vs == 1'b0) rd_idx <= 0;			// 场同步: FIFO 复位
		else if (lcd_request) rd_idx <= rd_idx + 1;
	end

	// ---- 与 example_top.v 相同的显示通路 ----
	wire [23:0] lcd_rgb888 = {lcd_data[15:11], lcd_data[13:11], lcd_data[10:6], lcd_data[8:6], lcd_data[5:1], lcd_data[3:1]};
	wire [23:0] lcd_left   = lcd_rgb888;						// 左半屏: 彩色
	wire [23:0] lcd_right  = 24'h101010;						// 右半屏: 二值(这里用深灰代表)
	wire [23:0] lcd_pixel  = (lcd_xpos < 12'd640) ? lcd_left : lcd_right;

	// ---- 多目标结果总线 (与 shape_recognizer 的打包格式一致) ----
	localparam TBW = 80;
	localparam MAXT = 4;
	reg [MAXT*TBW-1:0] tgt_bus;
	reg [3:0]          tgt_cnt;

	// {edge, ratio, y1, y0, x1, x0, shape}
	function [TBW-1:0] mk_tgt;
		input [1:0]   sh;
		input [10:0]  x0, x1;
		input [9:0]   y0, y1;
		input [15:0]  ratio;
		input [19:0]  ecnt;
		begin
			mk_tgt = {ecnt, ratio, y1, y0, x1, x0, sh};
		end
	endfunction

	// 三个目标的包围盒
	integer BX0 [0:2];
	integer BX1 [0:2];
	integer BY0 [0:2];
	integer BY1 [0:2];
	reg [23:0] BC [0:2];
	reg [3:0]  BN [0:2];			// 标签字数
	integer LY [0:2];				// 标签左上角 y (与 overlay 的放置规则一致)

	wire [23:0] lcd_ov;
	shape_overlay #(
		.S(2), .X_SHIFT(0), .LABEL_X(LBLX), .LABEL_Y(LBLY), .PAD(PAD), .BOX_THICK(2),
		.MAX_TARGETS(MAXT), .TBW(TBW), .XW(11), .YW(10), .TCNT_W(4),
		.H_ACTIVE(W), .V_ACTIVE(H)
	) u_ov (
		.clk(clk), .rst_n(rst_n), .de(lcd_request), .xpos(lcd_xpos), .ypos(lcd_ypos),
		.base(lcd_pixel), .target_count(tgt_cnt), .targets(tgt_bus),
		.valid(1'b1), .rgb(lcd_ov)
	);
	lcd_driver u_lcd (
		.clk(clk), .rst_n(rst_n), .lcd_dclk(), .lcd_blank(), .lcd_sync(),
		.lcd_request(lcd_request), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_en(lcd_de),
		.lcd_rgb({r2,g2,b2,r,g,b}), .lcd_xpos(lcd_xpos), .lcd_ypos(lcd_ypos), .lcd_data({lcd_ov, lcd_ov}));

	// ---- 抓两帧 ----
	integer fd, px = 0, py = 0, frames = 0, errors = 0, cap_id = -1;
	integer t, ymid, xchk;
	integer txt_px [0:2];
	integer none_txt = 0, none_pan = 0;
	reg prev_vs = 1, capturing = 0;
	reg [23:0] c;

	task start_capture;
		input [8*32-1:0] fname;
		input integer    id;
		begin
			fd = $fopen(fname, "wb");
			$fwrite(fd, "P6\n%0d %0d\n255\n", W, H);
			px = 0; py = 0; capturing = 1; cap_id = id;
		end
	endtask

	task frame_checks_multi;
		integer k;
		begin
			for (k = 0; k < NT; k = k + 1) begin
				if (txt_px[k] < 120) begin
					errors = errors + 1;
					$display("  [FAIL] target %0d label: only %0d text pixels", k, txt_px[k]);
				end else begin
					$display("  [ok]   target %0d label: %0d text pixels", k, txt_px[k]);
				end
			end
			if (py != H) begin
				errors = errors + 1;
				$display("  [FAIL] captured %0d lines, expect %0d", py, H);
			end
		end
	endtask

	task frame_checks_none;
		begin
			if (none_txt < 120) begin
				errors = errors + 1;
				$display("  [FAIL] no-target frame: only %0d 'unrecognized' text pixels", none_txt);
			end else begin
				$display("  [ok]   no-target frame: %0d 'unrecognized' text pixels", none_txt);
			end
			if (none_pan < 500) begin
				errors = errors + 1;
				$display("  [FAIL] no-target frame: text panel missing (%0d px)", none_pan);
			end else begin
				$display("  [ok]   no-target frame: text panel %0d px", none_pan);
			end
			if (py != H) begin
				errors = errors + 1;
				$display("  [FAIL] captured %0d lines, expect %0d", py, H);
			end
		end
	endtask

	always @(posedge clk) begin
		prev_vs <= lcd_vs;
		if (!prev_vs && lcd_vs) begin			// 场同步结束 = 一帧开始
			frames = frames + 1;
			if (frames == 2) start_capture("overlay_multi.ppm", 0);
			if (frames == 3) begin
				$fclose(fd);
				capturing = 0;
				$display(" ---- frame 1 (3 targets) ----");
				frame_checks_multi;
				tgt_cnt = 4'd0;				// 下一帧: 没有目标
				tgt_bus = {MAXT*TBW{1'b0}};
				start_capture("overlay_none.ppm", 1);
			end
			if (frames == 4) begin
				$fclose(fd);
				capturing = 0;
				$display(" ---- frame 2 (no target) ----");
				frame_checks_none;
				$display("=====================================================");
				if (errors == 0) $display(" RESULT: ALL CHECKS PASSED");
				else             $display(" RESULT: FAILED (%0d)", errors);
				$display("=====================================================");
				$finish;
			end
		end

		if (capturing && lcd_de) begin
			$fwrite(fd, "%c%c%c", r, g, b);
			c = {r, g, b};

			if (cap_id == 0) begin
				// ---- 第 1 帧: 三个目标 ----
				for (t = 0; t < NT; t = t + 1) begin
					ymid  = (BY0[t] + BY1[t]) / 2;
					xchk  = BX1[t] - 20;				// 避开标签底板(可能在框上方或框内左上角)
					// 4 条边必须在
					if ((px == BX0[t]) && (py == ymid) && (c !== BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d left border missing at (%0d,%0d) color=%h", t, px, py, c);
					end
					if ((px == BX1[t]) && (py == ymid) && (c !== BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d right border missing at (%0d,%0d) color=%h", t, px, py, c);
					end
					if ((px == xchk) && (py == BY0[t]) && (c !== BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d top border missing at (%0d,%0d) color=%h", t, px, py, c);
					end
					if ((px == xchk) && (py == BY1[t]) && (c !== BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d bottom border missing at (%0d,%0d) color=%h", t, px, py, c);
					end
					// 框外 1 像素不能是同色
					if (((px == BX0[t]-1) || (px == BX1[t]+1)) && (py == ymid) && (c === BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d border off by one at (%0d,%0d)", t, px, py);
					end
					if ((px == xchk) && (py == BY1[t]+1) && (c === BC[t])) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] t%0d bottom border off by one at (%0d,%0d)", t, px, py);
					end
					// 标签区域内的目标颜色像素 (标签在上方或框内左上角)
					if ((px >= BX0[t]) && (px < BX0[t] + BN[t]*GSZ) &&
					    (py >= LY[t]) && (py < LY[t] + GSZ) &&
					    (c === BC[t])) txt_px[t] = txt_px[t] + 1;

					// 任何位置都不允许出现"第三种"形状颜色被画成别的目标
					if ((c === BC[t]) &&
					    !((px >= BX0[t]) && (px <= BX1[t]) && (py >= BY0[t]) && (py <= BY1[t])) &&
					    !((px >= BX0[t]) && (px < BX0[t] + BN[t]*GSZ) &&
					      (py >= LY[t]) && (py < LY[t] + GSZ))) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] stray t%0d color at (%0d,%0d)", t, px, py);
					end
				end
			end else if (cap_id == 1) begin
				// ---- 第 2 帧: 无目标 ----
				for (t = 0; t < NT; t = t + 1)
					if (c === BC[t]) begin
						errors = errors + 1;
						if (errors < 20) $display("  [FAIL] no-target frame still draws shape color %h at (%0d,%0d)", c, px, py);
					end
				if ((px >= LBLX) && (px < LBLX + 3*GSZ) && (py >= LBLY) && (py < LBLY + GSZ) &&
				    (c === 24'hFF4040)) none_txt = none_txt + 1;
				if ((px >= LBLX-PAD) && (px < LBLX + 3*GSZ + PAD) &&
				    (py >= LBLY-PAD) && (py < LBLY + GSZ + PAD) && (c === 24'h101018))
					none_pan = none_pan + 1;
			end

			px = px + 1;
			if (px == W) begin px = 0; py = py + 1; end
		end
	end

	initial begin
		// 三个目标: 圆(左上) / 矩(中上) / 三角(右上, 顶到画面上沿 -> 标签落在框内左上角)
		BX0[0] = 100; BX1[0] = 300; BY0[0] = 120; BY1[0] = 320; BC[0] = 24'h00FFFF; BN[0] = 2;
		BX0[1] = 450; BX1[1] = 650; BY0[1] = 150; BY1[1] = 350; BC[1] = 24'h00FF00; BN[1] = 2;
		BX0[2] = 850; BX1[2] = 1050; BY0[2] =  20; BY1[2] = 220; BC[2] = 24'hFFFF00; BN[2] = 3;

		tgt_cnt = 4'd3;
		tgt_bus = {MAXT*TBW{1'b0}};
		tgt_bus[0*TBW +: TBW] = mk_tgt(2'd1, 11'd100,  11'd300,  10'd120, 10'd320, 16'd191, 20'd392);
		tgt_bus[1*TBW +: TBW] = mk_tgt(2'd2, 11'd450,  11'd650,  10'd150, 10'd350, 16'd256, 20'd336);
		tgt_bus[2*TBW +: TBW] = mk_tgt(2'd3, 11'd850,  11'd1050, 10'd 20, 10'd220, 16'd131, 20'd296);

		for (t = 0; t < NT; t = t + 1)
			LY[t] = (BY0[t] >= GSZ + PAD) ? (BY0[t] - GSZ - PAD) : (BY0[t] + 2);

		txt_px[0] = 0; txt_px[1] = 0; txt_px[2] = 0;

		repeat (10) @(posedge clk); rst_n = 1;
	end

	initial begin
		#400_000_000;
		$display("TIMEOUT");
		$finish;
	end
endmodule
