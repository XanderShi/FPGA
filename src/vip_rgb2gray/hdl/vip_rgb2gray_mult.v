`timescale 1 ps / 1 ps
// synopsys translate_on
// pipeline = 5 clks
module vip_rgb2gray_mult (
	clock,
	dataa,
	datab,
	result);
	input clock;
	input [7:0] dataa;
	input [9:0] datab;
	output [17:0] result;

	wire [31:0] mult_result;

	unsigned_multiplier_16x16_pp u_unsigned_multiplier_16x16_pp_0 (
		.clk(clock),
		.rst_n(1'b1),
		.a({8'd0,dataa}),
		.b({6'd0,datab}),
		.p(mult_result)
	);

	assign result = mult_result[17:0];
endmodule
