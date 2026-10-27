`timescale 1ns/1ps
// UI-control regression for the new K1/K2 gesture mapping.
module tb_sobel_ctrl;

localparam CLK_FREQ = 1000; // 1 clock = 1 ms in this model

integer errors = 0;
integer prev_cnt = 0;
integer next_cnt = 0;
integer thr_up_cnt = 0;
integer thr_dn_cnt = 0;

reg clk = 1'b0;
reg rst_n = 1'b0;
reg key1_n = 1'b1;
reg key2_n = 1'b1;
always #5 clk = ~clk;

wire [10:0] threshold;
wire [1:0]  mode;
wire [1:0]  display_mode;
wire        cfg_toggle;
wire        prev_frame;
wire        next_frame;

sobel_ctrl #(
	.CLK_FREQ(CLK_FREQ),
	.THR_DEFAULT(11'd64)
) dut (
	.clk(clk),
	.rst_n(rst_n),
	.key1_n(key1_n),
	.key2_n(key2_n),
	.threshold(threshold),
	.mode(mode),
	.display_mode(display_mode),
	.cfg_toggle(cfg_toggle),
	.prev_frame(prev_frame),
	.next_frame(next_frame)
);

always @(posedge clk) begin
	if (prev_frame) prev_cnt = prev_cnt + 1;
	if (next_frame) next_cnt = next_cnt + 1;
end

task key1_press(input integer ms);
begin
	@(negedge clk); key1_n = 1'b0;
	repeat(ms) @(posedge clk);
	@(negedge clk); key1_n = 1'b1;
	repeat(30) @(posedge clk);
end
endtask

task key2_press(input integer ms);
begin
	@(negedge clk); key2_n = 1'b0;
	repeat(ms) @(posedge clk);
	@(negedge clk); key2_n = 1'b1;
	repeat(30) @(posedge clk);
end
endtask

task check(input integer cond, input [8*72:1] name);
begin
	if (cond)
		$display("   [PASS] %0s", name);
	else begin
		$display("   [FAIL] %0s thr=%0d display_mode=%0d", name, threshold, display_mode);
		errors = errors + 1;
	end
end
endtask

integer t0;
integer p0;
integer n0;

initial begin
	$display("==============================================");
	$display(" frame UI control regression");
	$display("==============================================");

	repeat(20) @(posedge clk);
	rst_n = 1'b1;
	repeat(10) @(posedge clk);

	check((threshold == 11'd64) && (mode == 2'd2) && (display_mode == 2'd0),
		"reset: thr=64, Canny+target, live mode");
	check(cfg_toggle == 1'b1,
		"reset publishes initial threshold config across clock domains");

	t0 = threshold;
	key1_press(60);
	check(threshold == t0-8, "K1 short: threshold -8");

	t0 = threshold;
	key2_press(60);
	check(threshold == t0+8, "K2 short: threshold +8");

	t0 = threshold;
	key1_press(900);
	check((threshold == t0) && (display_mode == 2'd1),
		"K1 long: freeze, no threshold change");

	key1_press(60);
	check(threshold == t0-8, "K1 short in freeze: threshold still adjustable");

	key1_press(900);
	check(display_mode == 2'd0, "K1 long in freeze: return live");

	key2_press(900);
	check(display_mode == 2'd2, "K2 long: enter replay");

	t0 = threshold;
	p0 = prev_cnt;
	n0 = next_cnt;
	key1_press(60);
	key2_press(60);
	check((threshold == t0) && (prev_cnt == p0+1) && (next_cnt == n0+1),
		"replay: short keys select previous/next frame");

	key2_press(900);
	check(display_mode == 2'd0, "K2 long in replay: return live");

	$display("==============================================");
	if (errors == 0)
		$display(" RESULT: ALL CHECKS PASSED");
	else
		$display(" RESULT: %0d CHECK(S) FAILED", errors);
	$finish;
end

initial begin
	#2_000_000;
	$display(" TIMEOUT");
	$finish;
end

endmodule
