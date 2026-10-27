//======================================================================
//  rgb_align_ring.v   彩色原图延迟线 (按像素序号对齐), 块RAM环形缓冲
//
//  作用: 把输入端的 RGB565 原图延迟到与"边缘流水线输出"逐像素对齐,
//        同时把中值滤波后的 8bit 灰度延迟到同一时刻,
//        三者一起打包写 DDR (原图/中值对比、冻结、回放用)。
//
//  对齐原理 (与时钟延迟、valid 是否连续都无关):
//    * 写侧: 每个输入像素(in_valid)写一格, 帧首像素(in_sop)记下其地址 base
//    * 流水线每一级都是"一进一出", 输出帧第 n 个像素对应输入帧第 n - LAG 个像素
//      (每级 3x3 窗口序号滞后 WIDTH+1, 见 sim/tb_pipeline_latency.v、sim/tb_canny_edge.v)
//    * 读侧: 输出帧首像素时读地址 = base - LAG, 之后每输出一个像素地址 +1
//    * 环深 2^AW, 地址减法自然回绕; 要求 LAG + 流水线在途像素数 < 2^AW
//    * 中值灰度流本身比原图晚一个中值窗口(1281), 所以 GRAY_LAG = LAG - 1281
//
//  时序: 读 RAM 需要一拍, 所以 out_* 进来后打一拍, 在 pk_* 上与 pk_rgb 同拍输出。
//  仿真: sim/tb_edge_system.v (1280 宽整链路, valid 随机断续, 逐像素核对)
//======================================================================
module rgb_align_ring #(
	parameter        AW  = 13,			// 环深 2^AW
	parameter [31:0] LAG = 7686,		// RGB 到最终边缘输出的滞后
	parameter [31:0] GRAY_LAG = 6405	// 中值灰度到最终边缘输出的滞后
)(
	input				clk,
	// 写侧: 原图输入流
	input				in_valid,
	input				in_sop,
	input		[15:0]	in_rgb,
	// 写侧: 中值灰度流, 比原图晚一个中值窗口
	input				in_gray_valid,
	input				in_gray_sop,
	input		[7:0]	in_gray,
	// 读侧: 边缘流水线输出
	input				out_valid,
	input				out_sop,
	input				out_eop,
	input				out_edge,
	// 打包输出 (比 out_* 晚一拍)
	output	reg			pk_valid = 1'b0,
	output	reg			pk_sop   = 1'b0,
	output	reg			pk_eop   = 1'b0,
	output	reg			pk_edge  = 1'b0,
	output	reg	[15:0]	pk_rgb   = 16'd0,
	output	reg	[7:0]	pk_gray  = 8'd0
);
	reg  [15:0]   rgb_mem  [0:(1<<AW)-1];
	reg  [7:0]    gray_mem [0:(1<<AW)-1];
	reg  [AW-1:0] rgb_wptr  = {AW{1'b0}};
	reg  [AW-1:0] gray_wptr = {AW{1'b0}};
	reg  [AW-1:0] rgb_base  = {AW{1'b0}};
	reg  [AW-1:0] gray_base = {AW{1'b0}};
	reg  [AW-1:0] rgb_rptr  = {AW{1'b0}};
	reg  [AW-1:0] gray_rptr = {AW{1'b0}};

	always @(posedge clk) begin
		if (in_valid) begin
			rgb_mem[rgb_wptr] <= in_rgb;
			if (in_sop) rgb_base <= rgb_wptr;
			rgb_wptr <= rgb_wptr + 1'b1;
		end
		if (in_gray_valid) begin
			gray_mem[gray_wptr] <= in_gray;
			if (in_gray_sop) gray_base <= gray_wptr;
			gray_wptr <= gray_wptr + 1'b1;
		end
	end

	wire [AW-1:0] rgb_raddr  = (out_valid && out_sop) ? (rgb_base  - LAG[AW-1:0])      : rgb_rptr;
	wire [AW-1:0] gray_raddr = (out_valid && out_sop) ? (gray_base - GRAY_LAG[AW-1:0]) : gray_rptr;

	always @(posedge clk) begin
		if (out_valid) begin
			rgb_rptr  <= rgb_raddr  + 1'b1;
			gray_rptr <= gray_raddr + 1'b1;
		end
		pk_rgb   <= rgb_mem[rgb_raddr];		// 同步读, 推断块RAM
		pk_gray  <= gray_mem[gray_raddr];
		pk_valid <= out_valid;
		pk_sop   <= out_valid & out_sop;
		pk_eop   <= out_valid & out_eop;
		pk_edge  <= out_edge;
	end
endmodule
