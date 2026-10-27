`timescale 1ns/1ps
//======================================================================
//  tb_sobel_ctrl.v   按键控制单元测试
//
//   CLK_FREQ=1000, 1 个时钟 = 1ms 模型时间
//   消抖 20ms, 长按 800ms
//
//   T1 复位默认值
//   T2 K1/K2 短按调阈值
//   T3 抖动不产生动作
//   T4 K1 长按 -> 冻结(槽号=按下沿的 live_slot), 不调阈值
//   T5 K1 长按 -> 解除冻结
//   T6 K2 长按 -> 回放
//   T7 回放中 K1/K2 短按翻帧, 阈值不变
//   T8 K2 长按 -> 退出回放
//   T9 K1+K2 -> 算法模式循环, 不触发冻结
//   T10 cfg_toggle 上电推送
//======================================================================
module tb_sobel_ctrl;

localparam CLK_FREQ = 1000;

integer errors = 0;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;

reg key1_n = 1'b1;
reg key2_n = 1'b1;
reg [6:0] live_slot = 7'd3;
reg live_valid = 1'b1;
reg frames_ready = 1'b1;

wire [10:0] threshold;
wire [1:0]  mode;
wire        cfg_toggle;
wire [1:0]  disp_mode;
wire        freeze_enter;
wire [6:0]  freeze_slot_in;
wire        replay_enter;
wire        step_prev;
wire        step_next;

integer freeze_cnt = 0, replay_cnt = 0, prev_cnt = 0, next_cnt = 0;
integer cfg_cnt = 0;
reg cfg_d = 0;
always @(posedge clk) begin
	if (freeze_enter) freeze_cnt = freeze_cnt + 1;
	if (replay_enter) replay_cnt = replay_cnt + 1;
	if (step_prev)    prev_cnt   = prev_cnt + 1;
	if (step_next)    next_cnt   = next_cnt + 1;
	cfg_d <= cfg_toggle;
	if (cfg_d != cfg_toggle) cfg_cnt = cfg_cnt + 1;
end

sobel_ctrl #(.CLK_FREQ(CLK_FREQ)) dut (
	.clk(clk), .rst_n(rst_n),
	.key1_n(key1_n), .key2_n(key2_n),
	.live_slot(live_slot), .live_valid(live_valid), .frames_ready(frames_ready),
	.threshold(threshold), .mode(mode), .cfg_toggle(cfg_toggle),
	.disp_mode(disp_mode),
	.freeze_enter(freeze_enter), .freeze_slot_in(freeze_slot_in),
	.replay_enter(replay_enter), .step_prev(step_prev), .step_next(step_next)
);

//----------------------------------------------------------------------
task k1_press(input integer ms);
begin
	@(negedge clk); key1_n = 1'b0;
	repeat(ms) @(posedge clk);
	@(negedge clk); key1_n = 1'b1;
	repeat(30) @(posedge clk);
end
endtask

task k2_press(input integer ms);
begin
	@(negedge clk); key2_n = 1'b0;
	repeat(ms) @(posedge clk);
	@(negedge clk); key2_n = 1'b1;
	repeat(30) @(posedge clk);
end
endtask

task combo_press(input integer ms);
begin
	@(negedge clk); key1_n = 1'b0; key2_n = 1'b0;
	repeat(ms) @(posedge clk);
	@(negedge clk); key1_n = 1'b1; key2_n = 1'b1;
	repeat(30) @(posedge clk);
end
endtask

task chk(input cond, input [8*72:1] name);
begin
	if (cond) $display("   [PASS] %0s", name);
	else begin
		$display("   [FAIL] %0s  (thr=%0d mode=%0d disp=%0d freeze=%0d rep=%0d fz_slot=%0d)",
			name, threshold, mode, disp_mode, freeze_cnt, replay_cnt, freeze_slot_in);
		errors = errors + 1;
	end
end
endtask

//----------------------------------------------------------------------
initial begin
	$display("==== tb_sobel_ctrl ====");

	repeat (10) @(posedge clk);
	rst_n = 1'b1;
	repeat (60) @(posedge clk);

	// T1
	$display("-- T1 defaults --");
	chk(threshold == 11'd64, "default threshold = 64");
	chk(mode == 2'd2, "default algo mode = 2");
	chk(disp_mode == 2'd0, "default display = live");

	// T2 短按
	$display("-- T2 short press --");
	k1_press(100);
	chk(threshold == 11'd56, "K1 short: threshold -8");
	chk(freeze_cnt == 0, "K1 short: no freeze");
	k2_press(100);
	chk(threshold == 11'd64, "K2 short: threshold +8");

	// T3 抖动
	$display("-- T3 bounce --");
	@(negedge clk); key1_n = 1'b0; repeat(5) @(posedge clk);
	key1_n = 1'b1; repeat(5) @(posedge clk);
	key1_n = 1'b0; repeat(5) @(posedge clk);
	key1_n = 1'b1; repeat(40) @(posedge clk);
	chk(threshold == 11'd64, "bounce ignored");

	// T4 K1 长按冻结
	$display("-- T4 long press K1 freeze --");
	live_slot = 7'd5;
	k1_press(900);
	chk(disp_mode == 2'd1, "K1 long: display = freeze");
	chk(freeze_cnt == 1, "K1 long: freeze pulse");
	chk(freeze_slot_in == 7'd5, "K1 long: slot latched at key-down");
	chk(threshold == 11'd64, "K1 long: threshold unchanged");

	// T5 再长按解除
	$display("-- T5 long press K1 unfreeze --");
	k1_press(900);
	chk(disp_mode == 2'd0, "K1 long again: display = live");
	chk(freeze_cnt == 1, "no extra freeze pulse");

	// T6 K2 长按回放
	$display("-- T6 long press K2 replay --");
	k2_press(900);
	chk(disp_mode == 2'd2, "K2 long: display = replay");
	chk(replay_cnt == 1, "K2 long: replay pulse");

	// T7 回放翻帧
	$display("-- T7 replay step --");
	k1_press(100);
	chk(prev_cnt == 1, "replay: K1 short = prev frame");
	chk(threshold == 11'd64, "replay: threshold unchanged");
	k2_press(100);
	chk(next_cnt == 1, "replay: K2 short = next frame");

	// T8 退出回放
	$display("-- T8 exit replay --");
	k2_press(900);
	chk(disp_mode == 2'd0, "K2 long: back to live");

	// T9 组合键
	$display("-- T9 combo algo mode --");
	combo_press(100);
	chk(mode == 2'd0, "combo: algo 2 -> 0");
	combo_press(100);
	chk(mode == 2'd1, "combo: algo 0 -> 1");
	combo_press(100);
	chk(mode == 2'd2, "combo: algo 1 -> 2");
	chk(freeze_cnt == 1, "combo: no freeze");
	chk(disp_mode == 2'd0, "combo: still live");

	// T10 cfg_toggle
	$display("-- T10 cfg_toggle --");
	chk(cfg_cnt > 0, "cfg_toggle toggles on config change");

	if (errors == 0) $display("==== tb_sobel_ctrl PASS ====");
	else             $display("==== tb_sobel_ctrl FAIL (%0d) ====", errors);
	$finish;
end

initial begin
	repeat (200000) @(posedge clk);
	$display("==== tb_sobel_ctrl TIMEOUT ====");
	$finish;
end

endmodule
