//======================================================================
//  frame_ring_ctrl.v
//  100-frame DDR3 ring + dual-source display reader.
//
//  Physical layout (4 MiB aligned slot):
//    +0x000000 : 1280*720 raw RGB555/edge words, 16 bit
//    +0x200000 : 1280*720 median-gray words, 16 bit {8'h00,gray}
//
//  Slots 0..99   : chronological recording ring
//  Slots 100..101: live scratch while freeze/replay is active. This keeps
//                  the left live half moving without overwriting the
//                  frozen/replay slot. Historical-ring recording pauses
//                  only while one of those inspection modes is active.
//
//  Display modes:
//    0 = full-screen live frame (Canny edge + target overlay upstream)
//    1 = left live / right frozen, both reduced 2x2 into 640x360
//    2 = left live / right selected historical frame
//
//  DDR reading is time-multiplexed. The reader fills one R0_FIFO_16 in exact
//  LCD scan order, so the display side still consumes one 16-bit word/pixel.
//======================================================================
`timescale 1ns/1ps

module frame_ring_ctrl #(
	parameter integer H_ACTIVE    = 1280,
	parameter integer V_ACTIVE    = 720,
	parameter integer N_FRAMES    = 100,
	parameter [31:0]  SLOT_BYTES  = 32'h0040_0000,
	parameter [31:0]  MED_OFFSET  = 32'h0020_0000,
	parameter integer W_BURST     = 128,
	parameter integer R_BURST     = 8,
	parameter integer W_DATA_WHITE_TEST = 0
)(
	// AXI4 write address
	output wire [3:0]   axi_awid,
	output wire [31:0]  axi_awaddr,
	output wire [7:0]   axi_awlen,
	output wire [2:0]   axi_awsize,
	output wire [1:0]   axi_awburst,
	output wire         axi_awlock,
	output wire [3:0]   axi_awcache,
	output wire [2:0]   axi_awprot,
	output wire [3:0]   axi_awqos,
	output wire         axi_awvalid,
	input  wire         axi_awready,

	// AXI4 write data
	output wire [127:0] axi_wdata,
	output wire [15:0]  axi_wstrb,
	output wire         axi_wlast,
	output reg          axi_wvalid,
	input  wire         axi_wready,

	// AXI4 write response
	input  wire [3:0]   axi_bid,
	input  wire [1:0]   axi_bresp,
	input  wire         axi_bvalid,
	output wire         axi_bready,

	// AXI4 read address
	output wire [3:0]   axi_arid,
	output reg  [31:0]  axi_araddr,
	output wire [7:0]   axi_arlen,
	output wire [2:0]   axi_arsize,
	output wire [1:0]   axi_arburst,
	output wire         axi_arlock,
	output wire [3:0]   axi_arcache,
	output wire [2:0]   axi_arprot,
	output wire [3:0]   axi_arqos,
	output reg          axi_arvalid,
	input  wire         axi_arready,

	// AXI4 read data
	input  wire [3:0]   axi_rid,
	input  wire [127:0] axi_rdata,
	input  wire [1:0]   axi_rresp,
	input  wire         axi_rlast,
	input  wire         axi_rvalid,
	output reg          axi_rready,

	input  wire         axi_clk,
	input  wire         axi_reset,

	// Frame producer, camera pixel clock
	input  wire         wframe_clk,
	input  wire         wframe_rst,
	input  wire         wframe_sop,
	input  wire         wframe_eop,
	input  wire         wframe_valid,
	input  wire [15:0]  wframe_raw,
	input  wire [7:0]   wframe_gray,

	// Display consumer, LCD pixel clock
	input  wire         rframe_clk,
	input  wire         rframe_rst,
	input  wire         rframe_vsync,
	input  wire         rframe_data_en,
	output wire [15:0]  rframe_data,
	output wire         rframe_data_valid,

	// UI control/status, axi_clk domain
	input  wire [1:0]   display_mode,
	input  wire         prev_frame,
	input  wire         next_frame,
	output reg  [6:0]   live_slot,
	output reg  [6:0]   freeze_slot,
	output reg  [6:0]   replay_slot,
	output reg  [6:0]   ring_count,
	output reg  [6:0]   write_slot,
	output reg          write_slot_toggle,
	output reg          frame_commit,
	output reg          live_valid,
	output reg  [3:0]   read_debug,
	output reg          out_data_seen
);

localparam integer ROW_BYTES   = H_ACTIVE * 2;
localparam integer R_BURST_BYT = R_BURST * 16;
localparam integer ROW_BURSTS  = ROW_BYTES / R_BURST_BYT;
localparam integer BLACK_PACKS = H_ACTIVE / 8;
localparam integer PLANE_BYTES = H_ACTIVE * V_ACTIVE * 2;
localparam integer W_BURST_BYT = W_BURST * 16;
localparam integer RD_OUTSTANDING = 4;

localparam [6:0] SCRATCH0 = 7'd100;
localparam [6:0] SCRATCH1 = 7'd101;
localparam [16:0] FLUSH_TIMEOUT = 17'h1FFFF;

//----------------------------------------------------------------------
// AXI constants and write-side FIFOs
//----------------------------------------------------------------------
assign axi_awid    = 4'd0;
assign axi_awlen   = W_BURST - 1;
assign axi_awsize  = 3'd4;       // 16 bytes/beat
assign axi_awburst = 2'b01;      // INCR
assign axi_awlock  = 1'b0;
assign axi_awcache = 4'd3;
assign axi_awprot  = 3'd0;
assign axi_awqos   = 4'd0;
assign axi_wstrb   = 16'hffff;
assign axi_bready  = 1'b1;

assign axi_arid    = 4'd0;
assign axi_arlen   = R_BURST - 1;
assign axi_arsize  = 3'd4;
assign axi_arburst = 2'b01;
assign axi_arlock  = 1'b0;
assign axi_arcache = 4'd3;
assign axi_arprot  = 3'd0;
assign axi_arqos   = 4'd0;

wire [127:0] raw_fifo_rdata;
wire         raw_fifo_empty;
wire         raw_fifo_ren;
wire [9:0]   raw_fifo_count;

W0_FIFO_16 u_raw_wfifo (
	.prog_full_o  (),
	.full_o       (),
	.empty_o      (raw_fifo_empty),
	.prog_empty_o (),
	.wr_clk_i     (wframe_clk),
	.rd_clk_i     (axi_clk),
	.wr_en_i      (wframe_valid),
	.rd_en_i      (raw_fifo_ren),
	.wdata        (wframe_raw),
	.rst_busy     (),
	.rdata        (raw_fifo_rdata),
	.a_rst_i      (wframe_rst || axi_reset),
	.wr_datacount_o(),
	.rd_datacount_o(raw_fifo_count),
	.underflow_o  (),
	.overflow_o   ()
);

wire [127:0] med_fifo_rdata;
wire         med_fifo_empty;
wire         med_fifo_ren;
wire [9:0]   med_fifo_count;

W0_FIFO_16 u_med_wfifo (
	.prog_full_o  (),
	.full_o       (),
	.empty_o      (med_fifo_empty),
	.prog_empty_o (),
	.wr_clk_i     (wframe_clk),
	.rd_clk_i     (axi_clk),
	.wr_en_i      (wframe_valid),
	.rd_en_i      (med_fifo_ren),
	.wdata        ({8'h00,wframe_gray}),
	.rst_busy     (),
	.rdata        (med_fifo_rdata),
	.a_rst_i      (wframe_rst || axi_reset),
	.wr_datacount_o(),
	.rd_datacount_o(med_fifo_count),
	.underflow_o  (),
	.overflow_o   ()
);

//----------------------------------------------------------------------
// 100-frame write ring state
//----------------------------------------------------------------------
reg [14:0] commit_count;
reg [6:0]  ring_wr_slot;
reg [6:0]  scratch_wr_slot;
reg [6:0]  live_scratch_slot;
reg [6:0]  frame_target_slot;
reg        frame_target_ring;
reg        capture_active;
reg        flush_pending;
reg [16:0] flush_wait_cnt;
reg [1:0]  display_mode_d;
reg        dbg_aw_seen, dbg_w_seen, dbg_b_seen, dbg_commit_timeout;
reg [3:0]  committed_write_debug;

wire [7:0] oldest_full = (ring_wr_slot >= ring_count) ?
	(ring_wr_slot - ring_count) : (ring_wr_slot + N_FRAMES - ring_count);
wire [6:0] oldest_slot = oldest_full[6:0];
wire [6:0] newest_ring_slot = (ring_wr_slot == 0) ? (N_FRAMES-1) : (ring_wr_slot - 1'b1);

//----------------------------------------------------------------------
// Frame boundary CDC. The writer already has deep asynchronous FIFOs;
// toggles transfer only the frame start/end markers.
//----------------------------------------------------------------------
reg wframe_start_toggle, wframe_end_toggle;
always @(posedge wframe_clk or posedge wframe_rst) begin
	if (wframe_rst) begin
		wframe_start_toggle <= 1'b0;
		wframe_end_toggle <= 1'b0;
	end else begin
		if (wframe_sop)
			wframe_start_toggle <= ~wframe_start_toggle;
		if (wframe_eop)
			wframe_end_toggle <= ~wframe_end_toggle;
	end
end

reg start_tog_s1, start_tog_s2, start_tog_s3;
reg end_tog_s1, end_tog_s2, end_tog_s3;
wire frame_start_edge = start_tog_s2 ^ start_tog_s3;
wire frame_end_edge   = end_tog_s2 ^ end_tog_s3;

//----------------------------------------------------------------------
// AXI writer: alternate raw and median bursts, then commit the frame.
//----------------------------------------------------------------------
localparam [1:0] W_IDLE = 2'd0;
localparam [1:0] W_ADDR = 2'd1;
localparam [1:0] W_DATA = 2'd2;
localparam [1:0] W_DONE = 2'd3;

reg [1:0]  wstate;
reg        wr_src;          // 0=raw, 1=median
reg        last_wr_src;
reg [31:0] wr_cur_addr;
reg [31:0] raw_ptr, med_ptr;
reg [7:0]  wr_beat;
reg [10:0] wr_outstanding;
wire       wr_b_done = axi_bvalid && axi_bready;
wire       wr_last_beat = (wstate == W_DATA) && axi_wvalid && axi_wready &&
	(wr_beat == W_BURST-1);

// AXI cannot pause in the middle of this fixed-length write burst. Start a
// burst only after its complete 128-bit payload is present in the FIFO, and
// never write past the exact raw/median plane size.
wire raw_has_burst = (raw_fifo_count >= W_BURST) &&
	(raw_ptr <= (PLANE_BYTES - W_BURST_BYT));
wire med_has_burst = (med_fifo_count >= W_BURST) &&
	(med_ptr <= (PLANE_BYTES - W_BURST_BYT));
wire write_planes_done = (raw_ptr >= PLANE_BYTES) && (med_ptr >= PLANE_BYTES);
wire choose_med = med_has_burst && (!raw_has_burst || last_wr_src == 1'b0);
wire choose_raw = raw_has_burst && !choose_med;
wire write_slot_free = (wr_outstanding == 0);

assign axi_awaddr = wr_cur_addr;
assign axi_wdata  = (W_DATA_WHITE_TEST != 0) ? {128{1'b1}} :
	(wr_src ? med_fifo_rdata : raw_fifo_rdata);
assign axi_awvalid = (wstate == W_ADDR);
assign axi_wlast  = (wstate == W_DATA) && (wr_beat == W_BURST-1);
assign raw_fifo_ren = (wstate == W_DATA) && !wr_src && axi_wvalid && axi_wready;
assign med_fifo_ren = (wstate == W_DATA) &&  wr_src && axi_wvalid && axi_wready;

always @(posedge axi_clk) begin
	if (axi_reset) begin
		wstate <= W_IDLE;
		wr_src <= 1'b0;
		last_wr_src <= 1'b1;
		wr_cur_addr <= 32'd0;
		raw_ptr <= 32'd0;
		med_ptr <= 32'd0;
		wr_beat <= 8'd0;
		axi_wvalid <= 1'b0;
		wr_outstanding <= 11'd0;
		start_tog_s1 <= 1'b0;
		start_tog_s2 <= 1'b0;
		start_tog_s3 <= 1'b0;
		end_tog_s1 <= 1'b0;
		end_tog_s2 <= 1'b0;
		end_tog_s3 <= 1'b0;
		freeze_slot <= 7'd0;
		replay_slot <= 7'd0;
		display_mode_d <= 2'd0;
		frame_commit <= 1'b0;
		commit_count <= 15'd0;
		ring_wr_slot <= 7'd0;
		scratch_wr_slot <= SCRATCH0;
		live_scratch_slot <= SCRATCH0;
		ring_count <= 7'd0;
		write_slot <= 7'd0;
		write_slot_toggle <= 1'b0;
		live_slot <= 7'd0;
		capture_active <= 1'b0;
		flush_pending <= 1'b0;
		frame_target_ring <= 1'b1;
		frame_target_slot <= 7'd0;
		live_valid <= 1'b0;
		flush_wait_cnt <= 17'd0;
		dbg_aw_seen <= 1'b0;
		dbg_w_seen <= 1'b0;
		dbg_b_seen <= 1'b0;
		dbg_commit_timeout <= 1'b0;
		read_debug <= 4'd0;
		committed_write_debug <= 4'd0;
	end else begin
		frame_commit <= 1'b0;
		start_tog_s1 <= wframe_start_toggle;
		start_tog_s2 <= start_tog_s1;
		start_tog_s3 <= start_tog_s2;
		end_tog_s1 <= wframe_end_toggle;
		end_tog_s2 <= end_tog_s1;
		end_tog_s3 <= end_tog_s2;
		if (flush_pending && raw_fifo_empty && med_fifo_empty &&
			(flush_wait_cnt != FLUSH_TIMEOUT))
			flush_wait_cnt <= flush_wait_cnt + 1'b1;
		else if (!flush_pending)
			flush_wait_cnt <= 17'd0;
		if (wr_last_beat && !wr_b_done && (wr_outstanding != 11'h7ff))
			wr_outstanding <= wr_outstanding + 1'b1;
		else if (wr_b_done && !wr_last_beat && (wr_outstanding != 0))
			wr_outstanding <= wr_outstanding - 1'b1;
		if (axi_awvalid && axi_awready)
			dbg_aw_seen <= 1'b1;
		if (axi_wvalid && axi_wready)
			dbg_w_seen <= 1'b1;
		if (wr_b_done)
			dbg_b_seen <= 1'b1;

		// New frame. The frame-slot choice is frozen for the whole frame.
		if (frame_start_edge) begin
			capture_active <= 1'b1;
			flush_pending <= 1'b0;
			raw_ptr <= 32'd0;
			med_ptr <= 32'd0;
			frame_target_ring <= (display_mode == 2'd0);
			frame_target_slot <= (display_mode == 2'd0) ? ring_wr_slot : scratch_wr_slot;
			write_slot <= (display_mode == 2'd0) ? ring_wr_slot : scratch_wr_slot;
			write_slot_toggle <= ~write_slot_toggle;
			dbg_aw_seen <= 1'b0;
			dbg_w_seen <= 1'b0;
			dbg_b_seen <= 1'b0;
			dbg_commit_timeout <= 1'b0;
		end
		if (frame_end_edge && capture_active)
			flush_pending <= 1'b1;

		display_mode_d <= display_mode;
		if ((display_mode == 2'd1) && (display_mode_d != 2'd1))
			freeze_slot <= live_slot;
		if ((display_mode == 2'd2) && (display_mode_d != 2'd2))
			replay_slot <= (ring_count == 0) ? live_slot : newest_ring_slot;

		if ((display_mode == 2'd2) && (ring_count != 0)) begin
			if (prev_frame && (replay_slot != oldest_slot))
				replay_slot <= (replay_slot == 0) ? (N_FRAMES-1) : replay_slot - 1'b1;
			if (next_frame && (replay_slot != newest_ring_slot))
				replay_slot <= (replay_slot == N_FRAMES-1) ? 7'd0 : replay_slot + 1'b1;
		end

		case (wstate)
			W_IDLE: begin
				axi_wvalid <= 1'b0;
				wr_beat <= 8'd0;

				if (capture_active && write_slot_free &&
					(raw_has_burst || med_has_burst)) begin
					wr_cur_addr <= frame_target_slot * SLOT_BYTES +
						((choose_med) ? (MED_OFFSET + med_ptr) : raw_ptr);
					wr_src <= choose_med;
					last_wr_src <= choose_med;
					wstate <= W_ADDR;
				end else if (flush_pending && capture_active &&
					raw_fifo_empty && med_fifo_empty &&
					write_planes_done &&
					((wr_outstanding == 0) || (flush_wait_cnt == FLUSH_TIMEOUT))) begin
					capture_active <= 1'b0;
					flush_pending <= 1'b0;
					frame_commit <= 1'b1;
					live_slot <= frame_target_slot;
					live_valid <= 1'b1;
					commit_count <= commit_count + 1'b1;
					if (wr_outstanding != 0)
						dbg_commit_timeout <= 1'b1;
					committed_write_debug <= {
						(wr_outstanding != 0), dbg_b_seen, dbg_w_seen, dbg_aw_seen};

					if (frame_target_ring) begin
						ring_wr_slot <= (ring_wr_slot == N_FRAMES-1) ? 7'd0 : ring_wr_slot + 1'b1;
						if (ring_count < N_FRAMES)
							ring_count <= ring_count + 1'b1;
					end else begin
						live_scratch_slot <= frame_target_slot;
						scratch_wr_slot <= (frame_target_slot == SCRATCH0) ? SCRATCH1 : SCRATCH0;
					end
				end
			end

			W_ADDR: begin
				if (axi_awready) begin
					axi_wvalid <= 1'b1;
					wstate <= W_DATA;
				end
			end

			W_DATA: begin
				axi_wvalid <= 1'b1;
				if (axi_wready) begin
					if (wr_beat == W_BURST-1) begin
						axi_wvalid <= 1'b0;
						wr_beat <= 8'd0;
						if (wr_src)
							med_ptr <= med_ptr + W_BURST*16;
						else
							raw_ptr <= raw_ptr + W_BURST*16;
						wstate <= W_IDLE;
					end else begin
						wr_beat <= wr_beat + 1'b1;
					end
				end
			end

			default: begin
				wstate <= W_IDLE;
			end
		endcase
		read_debug <= committed_write_debug;
	end
end

//----------------------------------------------------------------------
// LCD-side frame edge. The FIFO reset lives in rframe_clk; a toggle is
// synchronized into the DDR reader clock to restart scan generation.
//----------------------------------------------------------------------
reg rframe_vsync_d;
reg [6:0] rframe_rst_cnt;
reg       rframe_frame_toggle;

always @(posedge rframe_clk) begin
	if (rframe_rst) begin
		rframe_vsync_d <= 1'b0;
		rframe_rst_cnt <= 7'd0;
		rframe_frame_toggle <= 1'b0;
	end else begin
		rframe_vsync_d <= rframe_vsync;
		if (rframe_vsync && !rframe_vsync_d) begin
			rframe_rst_cnt <= 7'd63;
			rframe_frame_toggle <= ~rframe_frame_toggle;
		end else if (rframe_rst_cnt != 0) begin
			rframe_rst_cnt <= rframe_rst_cnt - 1'b1;
		end
	end
end

wire rfifo_rst = axi_reset || (rframe_rst_cnt != 0);

wire [127:0] rfifo_wdata;
wire         rfifo_we;
reg  [127:0] rfifo_wdata_r;
reg          rfifo_we_r;
wire         rfifo_full;
wire         rfifo_empty;

assign rfifo_wdata = rfifo_wdata_r;
assign rfifo_we    = rfifo_we_r;

R0_FIFO_16 u_R0_FIFO_16 (
	.almost_full_o  (),
	.prog_full_o    (),
	.full_o         (rfifo_full),
	.wr_ack_o       (),
	.empty_o        (rfifo_empty),
	.almost_empty_o (),
	.rd_valid_o     (),
	.wr_clk_i       (axi_clk),
	.rd_clk_i       (rframe_clk),
	.wr_en_i        (rfifo_we),
	.rd_en_i        (rframe_data_en),
	.wdata          (rfifo_wdata),
	.rst_busy       (),
	.rdata          (rframe_data),
	.a_rst_i        (rfifo_rst),
	.wr_datacount_o (),
	.rd_datacount_o (),
	.underflow_o    (),
	.overflow_o     ()
);

assign rframe_data_valid = !rfifo_empty;

//----------------------------------------------------------------------
// DDR display reader / scan-order builder
//----------------------------------------------------------------------
reg       rframe_toggle_s1, rframe_toggle_s2, rframe_toggle_s3;
reg [7:0] start_wait;
reg       rd_active;
reg [9:0] out_y;

localparam [2:0] RD_SETUP    = 3'd0;
localparam [2:0] RD_BLACK    = 3'd1;
localparam [2:0] RD_AR       = 3'd2;
localparam [2:0] RD_AR_WAIT  = 3'd3;
localparam [2:0] RD_DATA     = 3'd4;
localparam [2:0] RD_NEXT_BST = 3'd5;
localparam [2:0] RD_NEXT_SEG = 3'd6;
localparam [2:0] RD_ROW_END  = 3'd7;

reg [2:0]  rd_state;
reg [1:0]  rd_mode_latched;
reg        rd_compare;
reg        rd_seg_right;
reg        rd_planar;       // 0=raw, 1=median
reg        rd_even;
reg [6:0]  rd_slot;
reg [6:0]  rd_live_slot;
reg [6:0]  rd_freeze_slot;
reg [6:0]  rd_replay_slot;
reg [9:0]  rd_src_y;
reg [2:0]  rd_cmd_idx;
reg [2:0]  rd_out_idx;
reg [2:0]  rd_ar_outstanding;
reg        rd_ar_busy;
reg [5:0]  rd_beat_idx;
reg [7:0]  rd_black_cnt;
reg [63:0] even_half;

wire [63:0] raw_even4 = {
	axi_rdata[111:96], axi_rdata[79:64],
	axi_rdata[47:32],  axi_rdata[15:0]
};

wire [31:0] rd_row_offset = rd_src_y * ROW_BYTES;
wire [31:0] rd_slot_base  = rd_slot * SLOT_BYTES;
wire [31:0] rd_plane_base = rd_slot_base + (rd_planar ? MED_OFFSET : 32'd0);
wire [31:0] rd_burst_addr = rd_plane_base + rd_row_offset + rd_cmd_idx*R_BURST_BYT;
wire [6:0]  rd_right_slot = (rd_mode_latched == 2'd2) ? rd_replay_slot : rd_freeze_slot;
wire        rd_ar_accept = (rd_state == RD_AR) && rd_ar_busy && axi_arready;
wire        rd_rburst_done = (rd_state == RD_AR) && axi_rvalid && axi_rready &&
	(rd_beat_idx == R_BURST-1);

// Fill the complete display FIFO before back-pressuring DDR reads. This gives
// the scan engine close to three LCD lines of prefetch against DDR latency.
wire fifo_has_room = !rfifo_full;

always @(posedge axi_clk) begin
	if (axi_reset) begin
		rframe_toggle_s1 <= 1'b0;
		rframe_toggle_s2 <= 1'b0;
		rframe_toggle_s3 <= 1'b0;
		start_wait <= 8'd0;
		rd_active <= 1'b0;
		out_y <= 10'd0;
		rd_state <= RD_ROW_END;
		rd_mode_latched <= 2'd0;
		rd_compare <= 1'b0;
		rd_seg_right <= 1'b0;
		rd_planar <= 1'b0;
		rd_even <= 1'b0;
		rd_slot <= 7'd0;
		rd_live_slot <= 7'd0;
		rd_freeze_slot <= 7'd0;
		rd_replay_slot <= 7'd0;
		rd_src_y <= 10'd0;
		rd_cmd_idx <= 3'd0;
		rd_out_idx <= 3'd0;
		rd_ar_outstanding <= 3'd0;
		rd_ar_busy <= 1'b0;
		rd_beat_idx <= 6'd0;
		rd_black_cnt <= 8'd0;
		even_half <= 64'd0;
		axi_arvalid <= 1'b0;
		axi_araddr <= 32'd0;
		axi_rready <= 1'b0;
		rfifo_we_r <= 1'b0;
		rfifo_wdata_r <= 128'd0;
		out_data_seen <= 1'b0;
	end else begin
		rfifo_we_r <= 1'b0;
		axi_arvalid <= 1'b0;
		axi_rready <= 1'b0;
		rframe_toggle_s1 <= rframe_frame_toggle;
		rframe_toggle_s2 <= rframe_toggle_s1;
		rframe_toggle_s3 <= rframe_toggle_s2;
		if (rd_ar_accept && !rd_rburst_done &&
			(rd_ar_outstanding != RD_OUTSTANDING))
			rd_ar_outstanding <= rd_ar_outstanding + 1'b1;
		else if (!rd_ar_accept && rd_rburst_done &&
			(rd_ar_outstanding != 0))
			rd_ar_outstanding <= rd_ar_outstanding - 1'b1;

		if (rframe_toggle_s2 ^ rframe_toggle_s3) begin
			start_wait <= 8'd128;
			rd_active <= 1'b1;
			out_y <= 10'd0;
			rd_state <= RD_SETUP;
			rd_seg_right <= 1'b0;
			rd_black_cnt <= 8'd0;
			rd_mode_latched <= display_mode;
			rd_live_slot <= live_slot;
			rd_freeze_slot <= freeze_slot;
			rd_replay_slot <= replay_slot;
		end else if (start_wait != 0) begin
			start_wait <= start_wait - 1'b1;
		end

		case (rd_state)
			RD_SETUP: begin
				axi_arvalid <= 1'b0;
				rd_cmd_idx <= 3'd0;
				rd_out_idx <= 3'd0;
				rd_ar_outstanding <= 3'd0;
				rd_ar_busy <= 1'b0;
				rd_beat_idx <= 6'd0;
				rd_seg_right <= 1'b0;

				if (out_y >= V_ACTIVE) begin
					rd_active <= 1'b0;
					rd_state <= RD_ROW_END;
				end else if (!live_valid) begin
					rd_black_cnt <= 8'd0;
					rd_state <= RD_BLACK;
				end else if (rd_mode_latched == 2'd0) begin
					rd_compare <= 1'b0;
					rd_planar <= 1'b0;
					rd_slot <= rd_live_slot;
					rd_src_y <= out_y;
					rd_even <= 1'b0;
					rd_state <= RD_AR;
				end else if ((out_y < 10'd180) || (out_y >= 10'd540)) begin
					rd_compare <= 1'b1;
					rd_black_cnt <= 8'd0;
					rd_state <= RD_BLACK;
				end else begin
					rd_compare <= 1'b1;
					rd_planar <= 1'b0;
					rd_slot <= rd_live_slot;
					rd_src_y <= (out_y - 10'd180) << 1;
					rd_even <= 1'b1;
					rd_state <= RD_AR;
				end
			end

			RD_BLACK: begin
				if ((start_wait == 0) && fifo_has_room) begin
					rfifo_we_r <= 1'b1;
					rfifo_wdata_r <= 128'd0;
					if (rd_black_cnt == BLACK_PACKS-1) begin
						rd_black_cnt <= 8'd0;
						rd_state <= RD_ROW_END;
					end else begin
						rd_black_cnt <= rd_black_cnt + 1'b1;
					end
				end
			end

			RD_AR: begin
				if (start_wait == 0) begin
					// Keep up to four read bursts in flight. Because all
					// requests use the same AXI ID, R beats return in order.
					if (rd_ar_busy) begin
						axi_arvalid <= 1'b1;
						if (axi_arready) begin
							axi_arvalid <= 1'b0;
							rd_ar_busy <= 1'b0;
							rd_cmd_idx <= rd_cmd_idx + 1'b1;
						end
					end else if (fifo_has_room &&
						(rd_ar_outstanding < RD_OUTSTANDING) &&
						(rd_cmd_idx < ROW_BURSTS)) begin
						axi_araddr <= rd_burst_addr;
						axi_arvalid <= 1'b1;
						rd_ar_busy <= 1'b1;
					end

					if ((rd_ar_outstanding != 0) && fifo_has_room)
						axi_rready <= 1'b1;

					if (axi_rvalid && axi_rready) begin
					if (axi_rdata[15:1] != 15'd0)
						out_data_seen <= 1'b1;
					if (!rd_even) begin
						rfifo_we_r <= 1'b1;
						rfifo_wdata_r <= axi_rdata;
					end else if (!rd_beat_idx[0]) begin
						even_half <= raw_even4;
					end else begin
						rfifo_we_r <= 1'b1;
						rfifo_wdata_r <= {raw_even4,even_half};
					end

					if (rd_beat_idx == R_BURST-1) begin
						rd_beat_idx <= 6'd0;
						rd_out_idx <= rd_out_idx + 1'b1;
						if (rd_out_idx == ROW_BURSTS-1)
							rd_state <= RD_NEXT_SEG;
					end else begin
						rd_beat_idx <= rd_beat_idx + 1'b1;
					end
				end
				end
			end

			RD_NEXT_SEG: begin
				if (rd_compare && !rd_seg_right && (rd_mode_latched != 2'd0)) begin
					rd_seg_right <= 1'b1;
					rd_slot <= rd_right_slot;
					rd_planar <= 1'b1;	// right half: frozen median-gray
					rd_src_y <= (out_y - 10'd180) << 1;
					rd_even <= 1'b1;
					rd_cmd_idx <= 3'd0;
					rd_out_idx <= 3'd0;
					rd_ar_outstanding <= 3'd0;
					rd_ar_busy <= 1'b0;
					rd_beat_idx <= 6'd0;
					rd_state <= RD_AR;
				end else begin
					rd_state <= RD_ROW_END;
				end
			end

			RD_ROW_END: begin
				if (rd_active) begin
					out_y <= out_y + 1'b1;
					rd_state <= RD_SETUP;
				end else begin
					out_y <= 10'd0;
				end
			end

			default: rd_state <= RD_ROW_END;
		endcase
	end
end

endmodule
