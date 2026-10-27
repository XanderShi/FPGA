//======================================================================
//  tb_edge_system.v   像素时钟域整链路系统仿真 (与 example_top.v 同样的连接)
//
//    RGB565 -> rgb2gray -> median_3x3 -> Sobeledge_8d_proc -> canny_edge
//           -> rgb_align_ring (彩色延迟线) -> 打包 -> shape_recognizer
//
//  宽度用真实的 1280 (PIPE_LAG = 6*1281 = 7686 与上板一致), 高度缩小以加快仿真。
//  输入流带行消隐、场消隐, GAPPY=1 时行内 valid 还会随机断续。
//
//  IMG=0  序号测试: 每个输入像素的 RGB 值 = 全局像素序号低 16 位,
//         逐像素检查 pk_rgb == 输入帧中第 (n - PIPE_LAG) 个像素  -> 验证彩色延迟线
//  IMG=1  图形测试: 依次送 圆 / 圆 / 矩形 / 三角形 四帧 (黄色图形 + 深色背景 + 椒盐噪声)
//         a) 每个输出像素的 pk_rgb 必须等于原图对应像素      -> 彩色与边缘逐像素对齐
//         b) 每个边缘像素在原图里 2 像素内必须有颜色跳变      -> 边缘确实落在物体轮廓上
//            (2 像素内有椒盐噪声点的单独计为噪声残留)
//         c) 每帧的识别结果 圆/圆/矩形/三角形                -> 高阶挑战6
//  MODE   0 = Sobel, 1 = Canny (与顶层模式含义一致, 2 与 1 的边缘相同)
//======================================================================
`timescale 1ns/1ps
module tb_edge_system;
	parameter IMG   = 1;
	parameter MODE  = 1;
	parameter GAPPY = 1;
	localparam W = 1280;
	localparam H = 240;
	localparam N = W*H;
	localparam NFRAME = 4;
	localparam [31:0] PIPE_LAG = 1281 + 1281 + 4*1281;	// 中值 + Sobel + Canny

	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;

	// ---------------- 输入流 ----------------
	reg        in_valid = 0, in_sop = 0, in_eop = 0;
	reg [15:0] in_rgb = 0;

	// ---------------- 与 example_top.v 相同的连接 ----------------
	wire gray_sop, gray_valid, gray_eop; wire [7:0] gray_data;
	vip_rgb2gray_proc #(.BPS(8)) u_gray (
		.clk(clk), .rst_n(rst_n),
		.sink_sop(in_sop), .sink_valid(in_valid), .sink_eop(in_eop),
		.sink_data({in_rgb[15:11],3'b111,in_rgb[10:5],2'b11,in_rgb[4:0],3'b111}),
		.source_sop(gray_sop), .source_valid(gray_valid), .source_data(gray_data), .source_eop(gray_eop));

	wire med_sop, med_valid, med_eop; wire [7:0] med_data;
	median_3x3 #(.WIDTH(W), .HEIGHT(H)) u_med (
		.clk(clk), .rst_n(rst_n),
		.sink_sop(gray_sop), .sink_eop(gray_eop), .sink_valid(gray_valid), .sink_data(gray_data),
		.source_sop(med_sop), .source_eop(med_eop), .source_valid(med_valid), .source_data(med_data));

	wire sobel_sop, sobel_eop, sobel_valid; wire [7:0] sobel_data, sobel_gray, sobel_bin;
	Sobeledge_8d_proc #(.WIDTH(W), .HEIGHT(H), .SOBEL_MODE_4DIR(1'b0)) u_sob (
		.clk(clk), .rst_n(rst_n), .mode(2'd2), .threshold(11'd64),
		.sink_sop(med_sop), .sink_eop(med_eop), .sink_valid(med_valid), .sink_data(med_data),
		.source_sop(sobel_sop), .source_eop(sobel_eop), .source_valid(sobel_valid),
		.source_data(sobel_data), .source_gray(sobel_gray), .source_bin(sobel_bin));

	wire edge_sop, edge_eop, edge_valid, canny_bit, sobel_bit;
	canny_edge #(.WIDTH(W), .HEIGHT(H)) u_canny (
		.clk(clk), .rst_n(rst_n), .th_high(11'd64), .th_low(11'd32),
		.sink_sop(sobel_sop), .sink_eop(sobel_eop), .sink_valid(sobel_valid),
		.sink_data(sobel_gray), .side_in(sobel_bin[7]),
		.source_sop(edge_sop), .source_eop(edge_eop), .source_valid(edge_valid),
		.source_edge(canny_bit), .side_out(sobel_bit));
	wire edge_bit = (MODE == 0) ? sobel_bit : canny_bit;

	wire pk_valid, pk_sop, pk_eop, pk_edge; wire [15:0] pk_rgb; wire [7:0] pk_gray;
	rgb_align_ring #(
		.AW(13), .LAG(PIPE_LAG), .GRAY_LAG(PIPE_LAG - 1281)
	) u_ring (
		.clk(clk),
		.in_valid(in_valid), .in_sop(in_sop), .in_rgb(in_rgb),
		.in_gray_valid(med_valid), .in_gray_sop(med_sop), .in_gray(med_data),
		.out_valid(edge_valid), .out_sop(edge_sop), .out_eop(edge_eop), .out_edge(edge_bit),
		.pk_valid(pk_valid), .pk_sop(pk_sop), .pk_eop(pk_eop), .pk_edge(pk_edge),
		.pk_rgb(pk_rgb), .pk_gray(pk_gray));

	wire [1:0] shp; wire [10:0] bx0, bx1; wire [9:0] by0, by1;
	wire [23:0] fe, fa; wire [15:0] fr; wire frv;
	shape_recognizer #(
		.H_ACTIVE(W), .V_ACTIVE(H), .XW(11), .YW(10), .CW(24),
		.MIN_EDGE(24'd400), .RECT_Q(16'd230), .CIRC_Q(16'd168), .TRI_Q(16'd96),
		.ROI_X0(400), .ROI_X1(879), .ROI_Y0(16), .ROI_Y1(H-17)	// 宽度 480, 高度随仿真画面缩小
	) u_shape (
		.clk(clk), .rst_n(rst_n),
		.st_sop(pk_sop), .st_eop(pk_eop), .st_valid(pk_valid), .st_data({8{pk_edge}}),
		.thresh(8'h80), .roi_en(1'b1),
		.shape(shp), .box_x0(bx0), .box_x1(bx1), .box_y0(by0), .box_y1(by1),
		.feat_edge(fe), .feat_area(fa), .feat_ratio_q(fr), .result_valid(frv));

	// ---------------- 测试图 ----------------
	reg [15:0] img [0:NFRAME-1][0:N-1];
	integer fshape [0:NFRAME-1];		// 期望识别结果 1圆 2矩形 3三角
	localparam [15:0] BG = 16'h2945, FG = 16'hFFE0;	// 深灰蓝背景 / 黄色图形
	integer f, x, y, i, seed;
	real dx, dy, half;
	initial begin
		seed = 7;
		for (f = 0; f < NFRAME; f = f + 1) begin
			fshape[f] = (f <= 1) ? 1 : (f == 2) ? 2 : 3;
			for (y = 0; y < H; y = y + 1)
				for (x = 0; x < W; x = x + 1) begin
					img[f][y*W+x] = BG;
					dx = x - 640; dy = y - 120;
					case (fshape[f])
						1: if (dx*dx + dy*dy <= 85.0*85.0) img[f][y*W+x] = FG;
						2: if (x >= 540 && x <= 740 && y >= 50 && y <= 190) img[f][y*W+x] = FG;
						3: begin
							half = (y - 40) * 0.75;
							if (y >= 40 && y <= 200 && (dx <= half) && (-dx <= half)) img[f][y*W+x] = FG;
						end
					endcase
				end
			for (i = 0; i < N/400; i = i + 1)		// 椒盐噪声(中值滤波应能滤掉)
				img[f][($unsigned($random(seed)) % N)] = ($random(seed) & 1) ? 16'hFFFF : 16'h0000;
		end
	end

	// ---------------- 送数 ----------------
	integer gidx = 0;				// 全局输入像素序号
	integer fbase [0:NFRAME-1];		// 每帧首像素的全局序号
	integer fin, k;
	initial begin
		repeat (10) @(posedge clk); rst_n <= 1; repeat (10) @(posedge clk);
		for (fin = 0; fin < NFRAME; fin = fin + 1) begin
			fbase[fin] = gidx;
			for (k = 0; k < N; k = k + 1) begin
				if (GAPPY) while (($random & 7) == 0) begin in_valid <= 0; in_sop <= 0; in_eop <= 0; @(posedge clk); end
				in_valid <= 1; in_sop <= (k == 0); in_eop <= (k == N-1);
				in_rgb   <= (IMG == 0) ? gidx[15:0] : img[fin][k];
				gidx = gidx + 1;
				@(posedge clk);
				if ((k % W) == W-1) begin			// 行消隐
					in_valid <= 0; in_sop <= 0; in_eop <= 0;
					repeat (40) @(posedge clk);
				end
			end
			in_valid <= 0; in_sop <= 0; in_eop <= 0;
			repeat (3*W) @(posedge clk);			// 场消隐
		end
		// 再送一帧背景把最后一帧的尾巴推出来
		for (k = 0; k < N; k = k + 1) begin
			in_valid <= 1; in_sop <= (k == 0); in_eop <= (k == N-1); in_rgb <= BG; gidx = gidx + 1;
			@(posedge clk);
		end
		in_valid <= 0; in_sop <= 0; in_eop <= 0;
		repeat (2000) @(posedge clk);
		report;
		$finish;
	end

	// ---------------- 检查 ----------------
	integer fo = -1, n = 0, src, sx, sy, ddx, ddy, nb;
	integer rgb_err = 0, rgb_chk = 0, edge_cnt = 0, edge_bad = 0, frame_err = 0;
	integer nres = 0, shape_err = 0;
	reg     near_change, near_noise;
	integer edge_noise = 0;
	reg [15:0] expv;
	always @(posedge clk) if (rst_n && pk_valid) begin
		if (pk_sop) begin
			if (fo >= 0 && n != N) begin frame_err = frame_err + 1; $display("  [FAIL] out frame %0d: %0d pixels", fo, n); end
			fo = fo + 1; n = 0;
		end
		if (fo >= 1 && fo < NFRAME) begin
			src = n - PIPE_LAG;			// 对应的输入帧内像素序号
			if (IMG == 0) begin
				expv = fbase[fo] + src;		// 可能落到上一帧尾部, 序号照样连续
				rgb_chk = rgb_chk + 1;
				if (pk_rgb !== expv) begin
					rgb_err = rgb_err + 1;
					if (rgb_err <= 5) $display("  [FAIL] frame %0d pix %0d: rgb=%h expect %h", fo, n, pk_rgb, expv);
				end
			end
			else if (src >= 0) begin
				rgb_chk = rgb_chk + 1;
				if (pk_rgb !== img[fo][src]) begin
					rgb_err = rgb_err + 1;
					if (rgb_err <= 5) $display("  [FAIL] frame %0d pix %0d: rgb=%h expect %h", fo, n, pk_rgb, img[fo][src]);
				end
				sx = src % W; sy = src / W;
				if (pk_edge && sx >= 8 && sx < W-8 && sy >= 8 && sy < H-8) begin
					edge_cnt = edge_cnt + 1;
					near_change = 0; near_noise = 0;
					for (ddy = -2; ddy <= 2; ddy = ddy + 1)
						for (ddx = -2; ddx <= 2; ddx = ddx + 1) begin
							nb = (sy+ddy)*W + (sx+ddx);
							if (img[fo][nb] != FG && img[fo][nb] != BG) near_noise = 1;
							// 只认"图形/背景"跳变, 椒盐噪声点不算
							if ((img[fo][nb] == FG) != (img[fo][src] == FG) &&
							    (img[fo][nb] == FG || img[fo][nb] == BG) && (img[fo][src] == FG || img[fo][src] == BG))
								near_change = 1;
						end
					if (!near_change && near_noise) edge_noise = edge_noise + 1;	// 贴着轮廓的椒盐噪声残留, 不算错
					else if (!near_change) begin
						edge_bad = edge_bad + 1;
						if (edge_bad <= 5) $display("  [WARN] frame %0d edge at (%0d,%0d) not near an object boundary", fo, sx, sy);
					end
				end
			end
		end
		n = n + 1;
	end

	// 识别结果: 第 r 个 result_valid 对应输出帧 r
	always @(posedge clk) if (frv) begin
		if (IMG == 1 && nres >= 1 && nres < NFRAME) begin
			$display("  out frame %0d: shape=%0d (expect %0d)  ratio_q=%0d edge=%0d area=%0d box=(%0d,%0d)-(%0d,%0d)",
			         nres, shp, fshape[nres], fr, fe, fa, bx0, by0, bx1, by1);
			if (shp != fshape[nres]) shape_err = shape_err + 1;
		end
		nres = nres + 1;
	end

	task report;
		begin
			$display("=====================================================");
			$display(" tb_edge_system  IMG=%0d MODE=%0d GAPPY=%0d  (W=%0d H=%0d PIPE_LAG=%0d)", IMG, MODE, GAPPY, W, H, PIPE_LAG);
			$display("  frame structure errors : %0d", frame_err);
			$display("  rgb alignment          : %0d checked, %0d errors", rgb_chk, rgb_err);
			if (IMG == 1) begin
				$display("  edge pixels            : %0d, noise residue: %0d, not on object boundary: %0d", edge_cnt, edge_noise, edge_bad);
				$display("  shape errors           : %0d", shape_err);
			end
			if (frame_err == 0 && rgb_err == 0 && rgb_chk > 0 &&
			    (IMG == 0 || (edge_bad == 0 && edge_cnt > 0 && shape_err == 0 && nres >= NFRAME)))
				$display(" RESULT: ALL CHECKS PASSED");
			else
				$display(" RESULT: FAILED");
			$display("=====================================================");
		end
	endtask
endmodule
