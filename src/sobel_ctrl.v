//======================================================================
//  sobel_ctrl.v   Threshold / freeze / 100-frame replay UI control
//
//  K1 short : threshold -8       (live/freeze modes) / previous frame
//  K2 short : threshold +8       (live/freeze modes) / next frame
//  K1 long  : freeze toggle, or leave replay
//  K2 long  : enter/leave replay
//
//  Short actions are committed on key release. A long press therefore
//  never produces an extra threshold step before the long action fires.
//  Inputs are active-low and use two-stage synchronizers plus debounce.
//======================================================================
module sobel_ctrl #(
	parameter CLK_FREQ      = 96_000_000,
	parameter DEBOUNCE_MS   = 20,
	parameter LONG_MS       = 800,
	parameter [10:0] THR_DEFAULT = 11'd256,
	parameter [10:0] THR_STEP    = 11'd8,
	parameter [10:0] THR_MAX     = 11'd2040
)(
	input              clk,
	input              rst_n,
	input              key1_n,
	input              key2_n,

	output reg  [10:0] threshold,
	output reg  [1:0]  mode,          // algorithm mode: fixed 2 here
	output reg  [1:0]  display_mode,  // 0=live full, 1=freeze compare, 2=replay
	output reg         cfg_toggle,
	output reg         prev_frame,
	output reg         next_frame
);

localparam CNT_DB   = (CLK_FREQ/1000)*DEBOUNCE_MS;
localparam CNT_LONG = (CLK_FREQ/1000)*LONG_MS;

//----------------------------------------------------------------------
// Asynchronous button synchronizers
//----------------------------------------------------------------------
reg k1_s1, k1_s2, k2_s1, k2_s2;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		k1_s1 <= 1'b1; k1_s2 <= 1'b1;
		k2_s1 <= 1'b1; k2_s2 <= 1'b1;
	end else begin
		k1_s1 <= key1_n; k1_s2 <= k1_s1;
		k2_s1 <= key2_n; k2_s2 <= k2_s1;
	end
end

//----------------------------------------------------------------------
// Debounce. Clean value: 1=released, 0=pressed.
//----------------------------------------------------------------------
reg k1_clean, k2_clean;
reg [20:0] db1_cnt, db2_cnt;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		k1_clean <= 1'b1; k2_clean <= 1'b1;
		db1_cnt <= 21'd0; db2_cnt <= 21'd0;
	end else begin
		if (k1_s2 != k1_clean) begin
			if (db1_cnt >= CNT_DB-1) begin
				k1_clean <= k1_s2;
				db1_cnt <= 21'd0;
			end else begin
				db1_cnt <= db1_cnt + 1'b1;
			end
		end else begin
			db1_cnt <= 21'd0;
		end

		if (k2_s2 != k2_clean) begin
			if (db2_cnt >= CNT_DB-1) begin
				k2_clean <= k2_s2;
				db2_cnt <= 21'd0;
			end else begin
				db2_cnt <= db2_cnt + 1'b1;
			end
		end else begin
			db2_cnt <= 21'd0;
		end
	end
end

wire p1 = ~k1_clean;
wire p2 = ~k2_clean;
reg  p1_d, p2_d;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		p1_d <= 1'b0; p2_d <= 1'b0;
	end else begin
		p1_d <= p1; p2_d <= p2;
	end
end

wire press1   = p1 & ~p1_d;
wire release1 = ~p1 & p1_d;
wire press2   = p2 & ~p2_d;
wire release2 = ~p2 & p2_d;

//----------------------------------------------------------------------
// Hold counters and one-shot long events
//----------------------------------------------------------------------
reg [26:0] hold1, hold2;
reg long1_done, long2_done;
reg long1, long2;
reg short1, short2;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		hold1 <= 27'd0; hold2 <= 27'd0;
		long1_done <= 1'b0; long2_done <= 1'b0;
		long1 <= 1'b0; long2 <= 1'b0;
		short1 <= 1'b0; short2 <= 1'b0;
	end else begin
		long1 <= 1'b0; long2 <= 1'b0;
		short1 <= 1'b0; short2 <= 1'b0;

		if (press1) begin
			hold1 <= 27'd0;
			long1_done <= 1'b0;
		end else if (p1 && !long1_done) begin
			if (hold1 >= CNT_LONG-1) begin
				long1 <= 1'b1;
				long1_done <= 1'b1;
			end else begin
				hold1 <= hold1 + 1'b1;
			end
		end

		if (release1) begin
			if (!long1_done)
				short1 <= 1'b1;
			long1_done <= 1'b1;
		end

		if (press2) begin
			hold2 <= 27'd0;
			long2_done <= 1'b0;
		end else if (p2 && !long2_done) begin
			if (hold2 >= CNT_LONG-1) begin
				long2 <= 1'b1;
				long2_done <= 1'b1;
			end else begin
				hold2 <= hold2 + 1'b1;
			end
		end

		if (release2) begin
			if (!long2_done)
				short2 <= 1'b1;
			long2_done <= 1'b1;
		end
	end
end

//----------------------------------------------------------------------
// Threshold and UI state
//----------------------------------------------------------------------
wire thr_down = short1 && (display_mode != 2'd2);
wire thr_up   = short2 && (display_mode != 2'd2);
wire step_prev = short1 && (display_mode == 2'd2);
wire step_next = short2 && (display_mode == 2'd2);

reg [1:0] display_mode_d;
wire mode_change;

always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		threshold      <= THR_DEFAULT;
		mode           <= 2'd2;
		display_mode   <= 2'd0;
		display_mode_d <= 2'd0;
		// Initial 1 is a valid toggle value: the pixel-clock synchronizer
		// resets to 0 and therefore captures THR_DEFAULT after reset.
		cfg_toggle     <= 1'b1;
		prev_frame     <= 1'b0;
		next_frame     <= 1'b0;
	end else begin
		display_mode_d <= display_mode;
		prev_frame <= step_prev;
		next_frame <= step_next;

		if (thr_down)
			threshold <= (threshold > THR_STEP) ? (threshold - THR_STEP) : 11'd0;
		else if (thr_up)
			threshold <= (threshold < (THR_MAX-THR_STEP)) ? (threshold + THR_STEP) : THR_MAX;

		if (long1) begin
			if (display_mode == 2'd0)
				display_mode <= 2'd1;
			else
				display_mode <= 2'd0;
		end else if (long2) begin
			if (display_mode == 2'd2)
				display_mode <= 2'd0;
			else
				display_mode <= 2'd2;
		end

		if (thr_down || thr_up || mode_change)
			cfg_toggle <= ~cfg_toggle;
	end
end

assign mode_change = (display_mode != display_mode_d);

endmodule
