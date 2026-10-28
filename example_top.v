`timescale 1ns/1ps

//	Efinity 工程文件被 IDE 重写时可能丢掉新加的 design_file 条目,
//	这里显式 include, 保证 frame_store 一定参与编译
`include "src/frame_store.v"

//`include "ddr3_controller.vh"


module example_top 
(
	////////////////////////////////////////////////////////////////
	//	External Clock & Reset
	//input 			nrst, 			//	Button K2
	input 			clk_24m,			//	24MHz Crystal
	input 			clk_25m,			//	25MHz Crystal 
	
	
	////////////////////////////////////////////////////////////////
	//	System Clock
	output 			sys_pll_rstn_o, 		
	
	input 			clk_sys,			//	Sys PLL 96MHz 
	input 			clk_pixel,			//	Sys PLL 74.25MHz
	input 			clk_pixel_2x,		//	Sys PLL 148.5MHz
	input 			clk_pixel_10x,		//	Sys PLL 742.5MHz
	
	input 			sys_pll_lock,		//	Sys PLL Lock
	
	////////////////////////////////////////////////////////////////
	//	MIPI-DSI Clock & Reset
	output 			dsi_pll_rstn_o,
	
	input 			dsi_refclk_i,		//	48MHz Reference Clock (for DSI PLL)
	input 			dsi_byteclk_i,		//	DSI Byte Clock (1X)
	input 			dsi_serclk_i,		//	DSI Serial Clock (4X 45)
	input 			dsi_txcclk_i,		//	DSI Serial Clock (4X 135)
	
	input 			dsi_pll_lock,
	
	////////////////////////////////////////////////////////////////
	//	DDR Clock
	output 			ddr_pll_rstn_o, 
	
	input 			tdqss_clk,			
	input 			core_clk,			//	DDR PLL 200MHz
	input 			tac_clk,			
	input 			twd_clk,			
	
	input 			ddr_pll_lock,		//	DDR PLL Lock
	
	////////////////////////////////////////////////////////////////
	//	DDR PLL Phase Shift Interface
	output 	[2:0] 	shift,
	output 	[4:0] 	shift_sel,
	output 			shift_ena,
	
	
	
	////////////////////////////////////////////////////////////////
	//	LVDS Clock
	output 			lvds_pll_rstn_o, 
	
	input 			clk_lvds_1x, 
	input 			clk_lvds_7x, 
	input 			clk_27m, 			//	RGB 1X Clock (16MHz)
	input 			clk_54m, 			//	RGB 2X Clock (32MHz, for export control)
	
	input 			lvds_pll_lock, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	DDR Interface Ports
	output 	[15:0] 	addr,
	output 	[2:0] 	ba,
	output 			we,
	output 			reset,
	output 			ras,
	output 			cas,
	output 			odt,
	output 			cke,
	output 			cs,
	
	//	DQ I/O
	input 	[15:0] 	i_dq_hi,
	input 	[15:0] 	i_dq_lo,
	
	output 	[15:0] 	o_dq_hi,
	output 	[15:0] 	o_dq_lo,
	output 	[15:0] 	o_dq_oe,
	
	//	DM O
	output 	[1:0] 	o_dm_hi,
	output 	[1:0] 	o_dm_lo,
	
	//	DQS I/O
	input 	[1:0] 	i_dqs_hi,
	input 	[1:0] 	i_dqs_lo,
	
	input 	[1:0] 	i_dqs_n_hi,
	input 	[1:0] 	i_dqs_n_lo,
	
	output 	[1:0] 	o_dqs_hi,
	output 	[1:0] 	o_dqs_lo,
	
	output 	[1:0] 	o_dqs_n_hi,
	output 	[1:0] 	o_dqs_n_lo,
	
	output 	[1:0] 	o_dqs_oe,
	output 	[1:0] 	o_dqs_n_oe,
	
	//	CK
	output 			clk_p_hi, 
	output 			clk_p_lo, 
	output 			clk_n_hi, 
	output 			clk_n_lo, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	MIPI-CSI Ctl / I2C
	output 			csi_ctl0_o,
	output 			csi_ctl0_oe,
	input 			csi_ctl0_i,
	
	output 			csi_ctl1_o,
	output 			csi_ctl1_oe,
	input 			csi_ctl1_i,
	
	output 			csi_scl_o,
	output 			csi_scl_oe,
	input 			csi_scl_i,
	
	output 			csi_sda_o,
	output 			csi_sda_oe,
	input 			csi_sda_i,
	
	//	MIPI-CSI RXC 
	input 			csi_rxc_lp_p_i,
	input 			csi_rxc_lp_n_i,
	output 			csi_rxc_hs_en_o,
	output 			csi_rxc_hs_term_en_o,
	input 			csi_rxc_i,
	
	//	MIPI-CSI RXD0
	output 			csi_rxd0_rst_o,
	output 			csi_rxd0_hs_en_o,
	output 			csi_rxd0_hs_term_en_o,
	
	input 			csi_rxd0_lp_p_i,
	input 			csi_rxd0_lp_n_i,
	input 	[7:0] 	csi_rxd0_hs_i,
	
	//	MIPI-CSI RXD1
	output 			csi_rxd1_rst_o,
	output 			csi_rxd1_hs_en_o,
	output 			csi_rxd1_hs_term_en_o,
	
	input 			csi_rxd1_lp_n_i,
	input 			csi_rxd1_lp_p_i,
	input 	[7:0] 	csi_rxd1_hs_i,
	
	//	MIPI-CSI RXD2
	output 			csi_rxd2_rst_o,
	output 			csi_rxd2_hs_en_o,
	output 			csi_rxd2_hs_term_en_o,
	
	input 			csi_rxd2_lp_p_i,
	input 			csi_rxd2_lp_n_i,
	input 	[7:0] 	csi_rxd2_hs_i,
	
	//	MIPI-CSI RXD3
	output 			csi_rxd3_rst_o,
	output 			csi_rxd3_hs_en_o,
	output 			csi_rxd3_hs_term_en_o,
	
	input 			csi_rxd3_lp_p_i,
	input 			csi_rxd3_lp_n_i,
	input 	[7:0] 	csi_rxd3_hs_i,
	
	//output 			csi_rxd0_fifo_rd_o, 
	//input 			csi_rxd0_fifo_empty_i, 
	//output 			csi_rxd1_fifo_rd_o, 
	//input 			csi_rxd1_fifo_empty_i, 
	//output 			csi_rxd2_fifo_rd_o, 
	//input 			csi_rxd2_fifo_empty_i, 
	//output 			csi_rxd3_fifo_rd_o, 
	//input 			csi_rxd3_fifo_empty_i, 
	
	
	
	////////////////////////////////////////////////////////////////
	//	DSI PWM & Reset Control 
	output 			dsi_pwm_o,			//	MIPI-DSI LCD PWM
	output 			dsi_resetn_o,		//	MIPI-DSI LCD Reset
	
	//	MIPI-DSI TXC / TXD
	output 			dsi_txc_rst_o,
	output 			dsi_txc_lp_p_oe,
	output 			dsi_txc_lp_p_o,
	output 			dsi_txc_lp_n_oe,
	output 			dsi_txc_lp_n_o,
	output 			dsi_txc_hs_oe,
	output 	[7:0] 	dsi_txc_hs_o,
	
	output 			dsi_txd0_rst_o,
	output 			dsi_txd0_hs_oe,
	output 	[7:0] 	dsi_txd0_hs_o,
	output 			dsi_txd0_lp_p_oe,
	output 			dsi_txd0_lp_p_o,
	output 			dsi_txd0_lp_n_oe,
	output 			dsi_txd0_lp_n_o,
	
	output 			dsi_txd1_rst_o,
	output 			dsi_txd1_lp_p_oe,
	output 			dsi_txd1_lp_p_o,
	output 			dsi_txd1_lp_n_oe,
	output 			dsi_txd1_lp_n_o,
	output 			dsi_txd1_hs_oe,
	output 	[7:0] 	dsi_txd1_hs_o,
	
	output 			dsi_txd2_rst_o,
	output 			dsi_txd2_lp_p_oe,
	output 			dsi_txd2_lp_p_o,
	output 			dsi_txd2_lp_n_oe,
	output 			dsi_txd2_lp_n_o,
	output 			dsi_txd2_hs_oe,
	output 	[7:0] 	dsi_txd2_hs_o,
	
	output 			dsi_txd3_rst_o,
	output 			dsi_txd3_lp_p_oe,
	output 			dsi_txd3_lp_p_o,
	output 			dsi_txd3_lp_n_oe,
	output 			dsi_txd3_lp_n_o,
	output 			dsi_txd3_hs_oe,
	output 	[7:0] 	dsi_txd3_hs_o,
	
	input 			dsi_txd0_lp_p_i,
	input 			dsi_txd0_lp_n_i,
	input 			dsi_txd1_lp_p_i,
	input 			dsi_txd1_lp_n_i,
	input 			dsi_txd2_lp_p_i,
	input 			dsi_txd2_lp_n_i,
	input 			dsi_txd3_lp_p_i,
	input 			dsi_txd3_lp_n_i,
	
	
	////////////////////////////////////////////////////////////////
	//	UART Interface
	input 		 	uart_rx_i,			//	Support 460800-8-N-1. 
	output 		 	uart_tx_o, 
	
	
	output 	[5:0] 	led_o,			//	
	
	
	////////////////////////////////////////////////////////////////
	//	User Keys (核心板丝印K1/K2, 低有效, BANK1A 1.8V)
	input 			key1_n,			//	K1 -> GPIOL_P_02(球N2): 阈值-
	input 			key2_n,			//	K2 -> GPIOL_N_02(球M2): 阈值+
	
	
	////////////////////////////////////////////////////////////////
	//	CMOS Sensor
	output 			cmos_sclk,
	input 			cmos_sdat_IN,
	output 			cmos_sdat_OUT,
	output 			cmos_sdat_OE,
	
	//	CMOS Interface
	input 			cmos_pclk,
	input 			cmos_vsync,
	input 			cmos_href,
	input 	[7:0] 	cmos_data,
	
	output 			cmos_ctl1_o, 
	output 			cmos_ctl1_oe, 
	input 			cmos_ctl1_i,
	output 			cmos_ctl2_o,
	output 			cmos_ctl2_oe, 
	input 			cmos_ctl2_i, 
	output 			cmos_ctl3_o,
	output 			cmos_ctl3_oe, 
	input 			cmos_ctl3_i, 
	
	
	////////////////////////////////////////////////////////////////
	//	HDMI Interface
	output 			hdmi_txc_oe,
	output 			hdmi_txd0_oe,
	output 			hdmi_txd1_oe,
	output 			hdmi_txd2_oe,
	
	output 			hdmi_txc_rst_o,
	output 			hdmi_txd0_rst_o,
	output 			hdmi_txd1_rst_o,
	output 			hdmi_txd2_rst_o,
	
	output 	[9:0] 	hdmi_txc_o,
	output 	[9:0] 	hdmi_txd0_o,
	output 	[9:0] 	hdmi_txd1_o,
	output 	[9:0] 	hdmi_txd2_o,
	
	
	////////////////////////////////////////////////////////////////
	//	LVDS Interface
	output 			lvds_txc_oe,
	output 	[6:0] 	lvds_txc_o,
	output 			lvds_txc_rst_o,
	
	output 			lvds_txd0_oe,
	output 	[6:0] 	lvds_txd0_o,
	output 			lvds_txd0_rst_o,
	
	output 			lvds_txd1_oe,
	output 	[6:0] 	lvds_txd1_o,
	output 			lvds_txd1_rst_o,
	
	output 			lvds_txd2_oe,
	output 	[6:0] 	lvds_txd2_o,
	output 			lvds_txd2_rst_o,
	
	output 			lvds_txd3_oe,
	output 	[6:0] 	lvds_txd3_o,
	output 			lvds_txd3_rst_o,
	
	
	////////////////////////////////////////////////////////////////
	//	RGB LCD 5Inch 800x480
	output 			lcd_tp_sda_o,		//	TP SDA
	output 			lcd_tp_sda_oe,
	input 			lcd_tp_sda_i,
	
	output 			lcd_tp_scl_o,		//	TP SCL
	output 			lcd_tp_scl_oe,
	input 			lcd_tp_scl_i,
	
	output 			lcd_tp_int_o,		//	TP INT
	output 			lcd_tp_int_oe,
	input 			lcd_tp_int_i,
	
	output 			lcd_tp_rst_o,		//	TP RST
	
	output 			lcd_pwm_o,			//	Backlight
	output 			lcd_blen_o,
	
	//output 			lcd_pclk_o,			//	PCLK & SCK Mux
	output 			lcd_vs_o,			//	VS & SSN Mux. Fixed to 1. Use DE-Only mode. 
	output 			lcd_hs_o,			//	HS. Fixed to 1. Use DE-Only mode. 
	//output 			lcd_de_o,			//	DE. (引脚GPIOL_P_02已改作key1_n)

	output 	[7:0] 	lcd_b7_0_o,			//	B7:B0. 
	output 	[7:0] 	lcd_g7_0_o,			//	G7:G0. Must output 8'hFF when access SPI. 
	output 	[7:0] 	lcd_r7_0_o,			//	R7:R0. 
	
	output 	[7:0] 	lcd_b7_0_oe,		//	B7:B0. 
	output 	[7:0] 	lcd_g7_0_oe,		//	G7:G0. Must output 8'hFF when access SPI. 
	output 	[7:0] 	lcd_r7_0_oe,		//	R7:R0. 

	input 	[7:0] 	lcd_b7_0_i,			//	B7:B0. 
	input 	[7:0] 	lcd_g7_0_i,			//	G7:G0. Must output 8'hFF when access SPI. 
	input 	[7:0] 	lcd_r7_0_i,			//	R7:R0. 
	
	//	SPI Pins
	output 			spi_sck_o, 
	output 			spi_ssn_o 			
);
	
	wire 			csi_rxd0_fifo_rd_o; 
	wire 			csi_rxd0_fifo_empty_i = 0;  
	wire 			csi_rxd1_fifo_rd_o;  
	wire 			csi_rxd1_fifo_empty_i = 0;  
	wire 			csi_rxd2_fifo_rd_o;  
	wire 			csi_rxd2_fifo_empty_i = 0;  
	wire 			csi_rxd3_fifo_rd_o;  
	wire 			csi_rxd3_fifo_empty_i = 0;  
	
	
	parameter 	SIM_DATA 	= 0; 
	
	//	Hardware Configuration
	assign clk_p_hi = 1'b0;	//	DDR3 Clock requires 180 degree shifted. 
	assign clk_p_lo = 1'b1;
	assign clk_n_hi = 1'b1;
	assign clk_n_lo = 1'b0; 
	
	assign cmos_ctl1_o = 0; 
	assign cmos_ctl1_oe = 1; 
	assign cmos_ctl2_o = 0; 
	assign cmos_ctl2_oe = 1; 
	assign cmos_ctl3_o = 0; 
	assign cmos_ctl3_oe = 1; 
	
	//	System Clock Tree Control
	assign sys_pll_rstn_o = 1'b1; 	//	nrst; 	//	Reset whole system when nrst (K2) is pressed. 
	
	assign dsi_pll_rstn_o = sys_pll_lock; 
	assign ddr_pll_rstn_o = sys_pll_lock; 
	assign lvds_pll_rstn_o = sys_pll_lock; 
	
	wire 			w_pll_lock = sys_pll_lock && dsi_pll_lock && ddr_pll_lock && lvds_pll_lock; 
	
	//	Synchronize System Resets. 
	reg 			rstn_sys = 0, rstn_pixel = 0; 
	wire 			rst_sys = ~rstn_sys, rst_pixel = ~rstn_pixel; 
	
	reg 			rstn_dsi_refclk = 0, rstn_dsi_byteclk = 0; 
	wire 			rst_dsi_refclk = ~rstn_dsi_refclk, rst_dsi_byteclk = ~rstn_dsi_byteclk; 
	
	reg 			rstn_lvds_1x = 0; 
	wire 			rst_lvds_1x = ~rstn_lvds_1x; 
	
	reg 			rstn_27m = 0, rstn_54m = 0; 
	wire 			rst_27m = ~rstn_27m, rst_54m = ~rstn_54m; 
	
	//	Clock Gen
	always @(posedge clk_27m or negedge w_pll_lock) begin if(~w_pll_lock) rstn_27m <= 0; else rstn_27m <= 1; end
	always @(posedge clk_54m or negedge w_pll_lock) begin if(~w_pll_lock) rstn_54m <= 0; else rstn_54m <= 1; end
	always @(posedge clk_sys or negedge w_pll_lock) begin if(~w_pll_lock) rstn_sys <= 0; else rstn_sys <= 1; end
	always @(posedge clk_pixel or negedge w_pll_lock) begin if(~w_pll_lock) rstn_pixel <= 0; else rstn_pixel <= 1; end
	always @(posedge dsi_refclk_i or negedge w_pll_lock) begin if(~w_pll_lock) rstn_dsi_refclk <= 0; else rstn_dsi_refclk <= 1; end
	always @(posedge dsi_byteclk_i or negedge w_pll_lock) begin if(~w_pll_lock) rstn_dsi_byteclk <= 0; else rstn_dsi_byteclk <= 1; end
	always @(posedge clk_lvds_1x or negedge w_pll_lock) begin if(~w_pll_lock) rstn_lvds_1x <= 0; else rstn_lvds_1x <= 1; end
	
	
	localparam 	CLOCK_MAIN 	= 96000000; 	//	System clock using 96MHz. 
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	Flash Burner Control
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	
	wire 			w_ustick, w_mstick; 
	
	wire  [7:0] 	w_dev_index_o;  
	wire  [7:0] 	w_dev_cmd_o;  
	wire  [31:0] 	w_dev_wdata_o;  
	wire  		w_dev_wvalid_o;  
	wire  		w_dev_rvalid_o;  
	wire 	[31:0] 	w_dev_rdata_i;  
	
	wire 			w_spi_ssn_o, w_spi_sck_o; 
	wire 	[3:0] 	w_spi_data_o, w_spi_data_oe; 
	wire 	[3:0] 	w_spi_data_i; 
	
	//	Flash Control
	reg 			r_flash_en = 0; 		//	0x00:0x00 Enable Flash
	
	always @(posedge clk_sys) begin
		r_flash_en <= (w_dev_wvalid_o && (w_dev_index_o == 8'h00) && (w_dev_cmd_o == 8'h00)) ? w_dev_wdata_o : r_flash_en; 
	end
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	LCD Data Mux
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	
	wire 	[7:0] 	w_lcd_b_o, w_lcd_g_o, w_lcd_r_o; 
	
	assign lcd_b7_0_o = r_flash_en ? {4'b0, w_spi_data_o[3:2], 2'b0} : w_lcd_b_o; 
	assign lcd_g7_0_o = r_flash_en ? {6'h0, w_spi_data_o[1:0]} : w_lcd_g_o; 
	assign lcd_r7_0_o = r_flash_en ? {8'h00} : w_lcd_r_o; 
	
	assign lcd_b7_0_oe = r_flash_en ? {4'b0, w_spi_data_oe[3:2], 2'b0} : 8'hFF; 
	assign lcd_g7_0_oe = r_flash_en ? {6'h0, w_spi_data_oe[1:0]} : 8'hFF; 
	assign lcd_r7_0_oe = r_flash_en ? {8'h00} : 8'hFF; 
	
	assign spi_sck_o = w_spi_sck_o; 
	assign spi_ssn_o = w_spi_ssn_o; 
	assign w_spi_data_i = {lcd_b7_0_i[3:2], lcd_g7_0_i[1:0]}; 
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	//	DDR3 Controller
	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	wire			w_ddr3_ui_clk = clk_sys;
	wire			w_ddr3_ui_rst = rst_sys;
	wire			w_ddr3_ui_areset = rst_sys;
	wire			w_ddr3_ui_aresetn = rstn_sys;
	

	//	General AXI Interface 
	wire	[3:0] 	w_ddr3_awid;
	wire	[31:0]	w_ddr3_awaddr;
	wire	[7:0]		w_ddr3_awlen;
	wire			w_ddr3_awvalid;
	wire			w_ddr3_awready;
	
	wire 	[3:0]  	w_ddr3_wid;
	wire 	[127:0] 	w_ddr3_wdata;
	wire 	[15:0]	w_ddr3_wstrb;
	wire			w_ddr3_wlast;
	wire			w_ddr3_wvalid;
	wire			w_ddr3_wready;
	
	wire 	[3:0] 	w_ddr3_bid;
	wire 	[1:0] 	w_ddr3_bresp;
	wire			w_ddr3_bvalid;
	wire			w_ddr3_bready;
	
	wire	[3:0] 	w_ddr3_arid;
	wire	[31:0]	w_ddr3_araddr;
	wire	[7:0]		w_ddr3_arlen;
	wire			w_ddr3_arvalid;
	wire			w_ddr3_arready;
	
	wire 	[3:0] 	w_ddr3_rid;
	wire 	[127:0] 	w_ddr3_rdata;
	wire			w_ddr3_rlast;
	wire			w_ddr3_rvalid;
	wire			w_ddr3_rready;
	wire 	[1:0] 	w_ddr3_rresp;
	
	
	//	AXI Interface Request
	wire 	[3:0] 	w_ddr3_aid;
	wire 	[31:0] 	w_ddr3_aaddr;
	wire 	[7:0]  	w_ddr3_alen;
	wire 	[2:0]  	w_ddr3_asize;
	wire 	[1:0]  	w_ddr3_aburst;
	wire 	[1:0]  	w_ddr3_alock;
	wire			w_ddr3_avalid;
	wire			w_ddr3_aready;
	wire			w_ddr3_atype;
	
	wire 			w_ddr3_cal_done, w_ddr3_cal_pass; 
	
	//	Do not issue DDR read / write when ~cal_done. 
	reg 			r_ddr_unlock = 0; 
	always @(posedge w_ddr3_ui_clk or negedge w_ddr3_ui_aresetn) begin
		if(~w_ddr3_ui_aresetn)
			r_ddr_unlock <= 0; 
		else
			r_ddr_unlock <= w_ddr3_cal_done; 
	end
	
	DdrCtrl ddr3_ctl_axi (	
		.core_clk		(core_clk),
		.tac_clk		(tac_clk),
		.twd_clk		(twd_clk),	
		.tdqss_clk		(tdqss_clk),
		
		.reset		(reset),
		.cs			(cs),
		.ras			(ras),
		.cas			(cas),
		.we			(we),
		.cke			(cke),    
		.addr			(addr),
		.ba			(ba),
		.odt			(odt),
		
		.o_dm_hi		(o_dm_hi),
		.o_dm_lo		(o_dm_lo),
		
		.i_dq_hi		(i_dq_hi),
		.i_dq_lo		(i_dq_lo),
		.o_dq_hi		(o_dq_hi),
		.o_dq_lo		(o_dq_lo),
		.o_dq_oe		(o_dq_oe),
		
		.i_dqs_hi		(i_dqs_hi),
		.i_dqs_lo		(i_dqs_lo),
		.i_dqs_n_hi		(i_dqs_n_hi),
		.i_dqs_n_lo		(i_dqs_n_lo),
		.o_dqs_hi		(o_dqs_hi),
		.o_dqs_lo		(o_dqs_lo),
		.o_dqs_n_hi		(o_dqs_n_hi),
		.o_dqs_n_lo		(o_dqs_n_lo),
		.o_dqs_oe		(o_dqs_oe),
		.o_dqs_n_oe		(o_dqs_n_oe),
		
		.clk			(w_ddr3_ui_clk),
		.reset_n		(w_ddr3_ui_aresetn),
		
		.axi_avalid		(w_ddr3_avalid),	//	Enable command only when unlocked. 
		.axi_aready		(w_ddr3_aready),
		.axi_aaddr		(w_ddr3_aaddr),
		.axi_aid		(w_ddr3_aid),
		.axi_alen		(w_ddr3_alen),
		.axi_asize		(w_ddr3_asize),
		.axi_aburst		(w_ddr3_aburst),
		.axi_alock		(w_ddr3_alock),
		.axi_atype		(w_ddr3_atype),
		
		.axi_wid		(w_ddr3_wid),
		.axi_wvalid		(w_ddr3_wvalid),
		.axi_wready		(w_ddr3_wready),
		.axi_wdata		(w_ddr3_wdata),
		.axi_wstrb		(w_ddr3_wstrb),
		.axi_wlast		(w_ddr3_wlast),
		
		.axi_bvalid		(w_ddr3_bvalid),
		.axi_bready		(w_ddr3_bready),
		.axi_bid		(w_ddr3_bid),
		.axi_bresp		(w_ddr3_bresp),
		
		.axi_rvalid		(w_ddr3_rvalid),
		.axi_rready		(w_ddr3_rready),
		.axi_rdata		(w_ddr3_rdata),
		.axi_rid		(w_ddr3_rid),
		.axi_rresp		(w_ddr3_rresp),
		.axi_rlast		(w_ddr3_rlast),
		
		.shift		(shift),
		.shift_sel		(),
		.shift_ena		(shift_ena),
		
		.cal_ena		(1'b1),
		.cal_done		(w_ddr3_cal_done),
		.cal_pass		(w_ddr3_cal_pass)
	);
	
	assign shift_sel = 5'b00100; 		//	ddr_tac_clk always use PLLOUT[2]. 
	
	
	AXI4_AWARMux #(.AID_LEN(4), .AADDR_LEN(32)) axi4_awar_mux (
		.aclk_i			(w_ddr3_ui_clk), 
		.arst_i			(w_ddr3_ui_rst), 
		
		.awid_i			(w_ddr3_awid),
		.awaddr_i			(w_ddr3_awaddr),
		.awlen_i			(w_ddr3_awlen),
		.awvalid_i			(w_ddr3_awvalid && r_ddr_unlock),
		.awready_o			(w_ddr3_awready),
		
		.arid_i			(w_ddr3_arid),
		.araddr_i			(w_ddr3_araddr),
		.arlen_i			(w_ddr3_arlen),
		.arvalid_i			(w_ddr3_arvalid && r_ddr_unlock),
		.arready_o			(w_ddr3_arready),
		
		.aid_o			(w_ddr3_aid),
		.aaddr_o			(w_ddr3_aaddr),
		.alen_o			(w_ddr3_alen),
		.atype_o			(w_ddr3_atype),
		.avalid_o			(w_ddr3_avalid),
		.aready_i			(w_ddr3_aready)
	);
	
	
	//assign led_o[1:0] = {w_ddr3_cal_pass, w_ddr3_cal_done}; 
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////
	//	I2C Config (OV5640)
	
	//  i2c timing controller module of 16Bit
	wire            [ 7:0]          ov5640_i2c_config_index;
	wire            [23:0]          ov5640_i2c_config_data;
	wire            [ 7:0]          ov5640_i2c_config_size;
	wire                            ov5640_i2c_config_done;
	wire            [15:0]          ov5640_i2c_rdata;                              //  i2c register data

	i2c_timing_ctrl_16bit
	#(
	    .CLK_FREQ           (CLOCK_MAIN),                              //  100 MHz
	    .I2C_FREQ           (50_000    )                               //  10 KHz(<= 400KHz)
	) 
	u_i2c_timing_ctrl_16bit 
	(
	    //global clock
	    .clk                (clk_sys                 ),                          //  96MHz
	    .rst_n              (rstn_sys                ),                          //  system reset

	    //i2c interface
	    .i2c_sclk           (cmos_sclk                  ),                  //  i2c clock
		.i2c_sdat_OUT 	(cmos_sdat_OUT), 
		.i2c_sdat_OE	(cmos_sdat_OE), 
		.i2c_sdat_IN 	(cmos_sdat_IN), 
		
	    //i2c config data
	    .i2c_config_index   (ov5640_i2c_config_index           ),                  //  i2c config reg index, read 2 reg and write xx reg
	    .i2c_config_data    ({8'h78, ov5640_i2c_config_data}   ),                  //  i2c config data
	    .i2c_config_size    (ov5640_i2c_config_size            ),                  //  i2c config data counte
	    .i2c_config_done    (ov5640_i2c_config_done            ),                  //  i2c config timing complete
	    .i2c_rdata          (ov5640_i2c_rdata                  )                   //  i2c register data while read i2c slave
	);
	
	//----------------------------------------------------------------------
	//  I2C Configure Data of OV5640
	I2C_OV5640_1280720_Config u_I2C_OV5640_1280720_Config
	(
	    .LUT_INDEX  (ov5640_i2c_config_index   ),
	    .LUT_DATA   (ov5640_i2c_config_data    ),
	    .LUT_SIZE   (ov5640_i2c_config_size    )
	); 
	
	
	//	CMOS Interface
	//input 			cmos_pclk,
	//input 			cmos_vsync,
	//input 			cmos_href,
	//input 	[7:0] 	cmos_data,
	
	wire 			w_cmos_pclk = cmos_pclk; 
	
	
	
	//	Output LED
	reg 	[3:0]		r_cmos_fv_o = 0; 
	reg 	[1:0] 	r_cmos_rx_vsync0_in = 0; 
	always @(posedge w_cmos_pclk) begin
		r_cmos_rx_vsync0_in <= {r_cmos_rx_vsync0_in, cmos_vsync}; 
		r_cmos_fv_o <= r_cmos_fv_o + ((r_cmos_rx_vsync0_in == 2'b01) ? 1 : 0); 
	end
	//assign led_o[5] = r_cmos_fv_o[3]; 	//原:相机帧计数指示, 现改为显示模式指示
	
	
	
	
	
	
	
	
	////////////////////////////////////////////////////////////////
	//	System Control. Can be removed for public. 
	
	localparam 	CLK_FREQ 	= 96_000_000; 	//	clk_sys is 96MHz. 
	localparam 	BAUD_RATE 	= 460_800; 		//	Use 460800-8-N-1. 
	
	
	//	SFR I/O Interface
	wire 	[7:0] 	w_sfr_addr_o; 	//	SFR Address (0xFF00 ~ 0xFFFF). 00:Power; 40~5F:Stream0; 60~7F:Stream1. 
	wire 	[7:0] 	w_sfr_wdata_o; 	//	SFR Write Data. 
	wire 			w_sfr_we_o; 		//	SFR WE. 
	reg 	[7:0] 	w_sfr_rdata_i; 	//	Must be valid after sfr_rd_o. 
	wire 			w_sfr_rd_o; 		//	SFR RD. 
	
	
	//	System Control Registers
	reg 			r_dsi_tx_rstn = 0; 	//	DSI TX Reset
	reg 	[7:0] 	r_dsi_pwm = 64; 		//	[6:0]PWM, [7]Pol
	reg 			r_dsi_resetn_o = 0; 	//	DSI Panel Reset
	reg 			r_dsi_data_rstn = 0; 	//	DSI TX Reset
	
	reg 	[3:0] 	r_dsi_lp_p_ovr = 0; 	
	reg 	[3:0] 	r_dsi_lp_n_ovr = 0; 	
	
	
	
	//	AXI-Lite Interface Bridge
	localparam 	CSI_AXILITE_ID 	= 0; 				//	Select DSI_TX when r_axi_sel = DSI_AXILITE_ID. 
	localparam 	DSI_AXILITE_ID 	= 1; 				//	Select DSI_TX when r_axi_sel = DSI_AXILITE_ID. 
	
	reg 	[7:0] 	r_axi_addr = 8'h18; 		//	0xE0 (RW)
	reg 	[31:0] 	r_axi_wdata = 32'h0000000A; 	//	0xE1~0xE4 (RW)
	wire 	[31:0] 	w_axi_rdata; 			//	0xE5~0xE8 (RO)
	reg 	[0:0] 	r_axi_sel = 1; 			//	0xE9[7:2] (RW)
	reg 			r_axi_r1w0 = 0; 			//	0xE9[1] (RW)
	reg 			r_axi_req = 0; 			//	0xE9[0] (WO, Single Cycle)
	reg 			r_axi_req_o = 0; 			//	Delayed of r_axi_req. 
	
	
	//	Buffered AXI Read Data
	reg 	[31:0] 	r_axi_rdata = 0; 		//	Use state machine
	reg 			r_axi_idle = 0; 		//	AXI Idle 
	
	reg 	[3:0] 	rs_axilite = 0; 		//	AXI Access
	wire 	[3:0] 	ws_axilite_idle = 0; 		
	wire 	[3:0] 	ws_axilite_write = 1; 
	wire 	[3:0] 	ws_axilite_read = 2; 
	wire 	[3:0] 	ws_axilite_endread = 3; 
	
	reg 			r_axi_awvalid = 0, r_axi_wvalid = 0, r_axi_arvalid = 0; 
	wire 			w_axi_awready, w_axi_wready, w_axi_arready, w_axi_rvalid; 
	
	
	reg 	[3:0] 	rc_axi_init = 0; 

	always @(posedge clk_sys or posedge rst_sys) begin
		if(rst_sys) begin
			r_dsi_tx_rstn <= 0; 
			r_dsi_pwm <= 64; 
			r_axi_req <= 0; 
			r_dsi_resetn_o <= 0; 
			r_dsi_data_rstn <= 0; 
			
			rs_axilite <= 0; 
			r_axi_awvalid <= 0; 
			r_axi_wvalid <= 0;
			r_axi_arvalid <= 0; 
			
			r_dsi_lp_p_ovr <= 0; 
			r_dsi_lp_n_ovr <= 0; 
			
			rc_axi_init <= 0; 
			r_axi_idle <= 0; 
			
		end else begin
			r_dsi_tx_rstn <= 1; 
			r_dsi_resetn_o <= 1; 
			r_dsi_data_rstn <= 1; 
			
		end
	end
	
	assign dsi_resetn_o = r_dsi_resetn_o; 
	
	assign csi_ctl0_oe = 0; 
	assign csi_ctl1_oe = 0; 
	
	
	PWMLite dsi_pwm (		//	#(.ENABLE_TICK(0), .PWM_BITS(7)) 
		.clk_i			(clk_sys),
		.rst_i			(rst_sys),
		.pwm_i			(r_dsi_pwm[6:0]),
		.pol_i			(r_dsi_pwm[7]), 
		.pwm_o			(dsi_pwm_o)
	);






	////////////////////////////////////////////////////////////////
	//	MIPI CSI RX
	
	//	The CSI RXC shall not be inverted. Data can be inverted with swapped LP data and flipped HS data. 
	localparam 	CSI_RXD_INV 	= 4'b1111; 
	localparam 	CSI_DATA_WIDTH 	= 8; 			
	localparam 	CSI_STRB_WIDTH 	= CSI_DATA_WIDTH / 8; 

	
	////////////////////////////////////////////////////////////////
	//	MIPI-CSI Crop
	
	wire			XYCrop_frame_vsync; 
	wire			XYCrop_frame_href;
	wire			XYCrop_frame_de;
	wire	[63:0]	XYCrop_frame_Gray;

	Sensor_Image_XYCrop
	#(
		//	RGB width doubled. 
		.IMAGE_HSIZE_SOURCE (1280 * 2 / CSI_STRB_WIDTH),
		.IMAGE_VSIZE_SOURCE (720	 ),
		.IMAGE_HSIZE_TARGET (1280 * 2 / CSI_STRB_WIDTH),
		.IMAGE_YSIZE_TARGET (720 	 ),
		.PIXEL_DATA_WIDTH	(CSI_DATA_WIDTH) 		//	32		 )
	)
	u_Sensor_Image_XYCrop
	(
		//	globel clock
		.clk			(w_cmos_pclk),			//	image pixel clock
		.rst_n		(rstn_sys),			//	system reset
		
		//CMOS Sensor interface
		.image_in_vsync (cmos_vsync		),			//H : Data Valid; L : Frame Sync(Set it by register)
		.image_in_href	(cmos_href		),			//H : Data vaild, L : Line Sync
		.image_in_de	(cmos_href		), 			//H : Data Enable, L : Line Sync
		.image_in_data	(cmos_data),			//8 bits cmos data input
		
		.image_out_vsync(XYCrop_frame_vsync ),			//H : Data Valid; L : Frame Sync(Set it by register)
		.image_out_href (XYCrop_frame_href	),			//H : Data vaild, L : Line Sync
		.image_out_de	(XYCrop_frame_de	), 			//H : Data Enable, L : Line Sync
		.image_out_data (XYCrop_frame_Gray	)			//8 bits cmos data input	
	);
//摄像头采集模块，dvp转avalon-st裸流
wire [15:0] data_w0;
wire valid_w0,ready_w0,sop_w0,eop_w0;	
cmos_top u_cmos_top_0( 
		.clk         (w_cmos_pclk),
		.rst_n       (rstn_sys  ),
		.cmos_pclk   (w_cmos_pclk ),       //  cmos.pclk
		.cmos_vsync  (cmos_vsync),         //      .vsync
		.cmos_href   (cmos_href ),         //      .href
		.cmos_data   (cmos_data ),         //      .data
		.source_sop  (sop_w0    ),
		.source_valid(valid_w0  ),
		.source_data (data_w0   ),
		.source_eop  (eop_w0    ),
		.source_ready(1'b1      )
);
//RGB转灰度：cmos_top输出 -> 灰度8bit
wire        gray_sop, gray_valid, gray_eop;
wire [7:0]  gray_data;
vip_rgb2gray_proc #(.BPS(8)) u_vip_rgb2gray_proc (
	.clk         (w_cmos_pclk),
	.rst_n       (rstn_sys  ),
	.sink_sop    (sop_w0    ),
	.sink_valid  (valid_w0  ),
	.sink_data   ({data_w0[15:11],3'b111,data_w0[10:5],2'b11,data_w0[4:0],3'b111}   ),
	.sink_eop    (eop_w0    ),
	.source_sop  (gray_sop  ),
	.source_valid(gray_valid),
	.source_data (gray_data ),
	.source_eop  (gray_eop  )
);
//Sobel边缘检测：灰度8bit -> 边缘强度/二值边缘/原图
//3x3中值滤波：灰度 -> 去噪后灰度 (高阶挑战1), 插在灰度化之后、Sobel之前
localparam MEDIAN_EN = 1'b1;		//1=启用中值滤波  0=旁路(保留原始灰度直通)
wire        med_sop, med_valid, med_eop;
wire [7:0]  med_data;
median_3x3 #(
	.WIDTH(1280),
	.HEIGHT(720)
) u_median_3x3 (
	.clk         (w_cmos_pclk),
	.rst_n       (rstn_sys  ),
	.sink_sop    (gray_sop  ),
	.sink_eop    (gray_eop  ),
	.sink_valid  (gray_valid),
	.sink_data   (gray_data ),
	.source_sop  (med_sop   ),
	.source_eop  (med_eop   ),
	.source_valid(med_valid ),
	.source_data (med_data  )
);
//	Sobel 输入: 默认用中值滤波后的数据; MEDIAN_EN=0 时直通原始灰度(方便做对比实验)
wire        sobel_in_sop   = MEDIAN_EN ? med_sop   : gray_sop;
wire        sobel_in_eop   = MEDIAN_EN ? med_eop   : gray_eop;
wire        sobel_in_valid = MEDIAN_EN ? med_valid : gray_valid;
wire [7:0]  sobel_in_data  = MEDIAN_EN ? med_data  : gray_data;
//Sobel边缘检测：灰度8bit -> 边缘强度/二值边缘/原图
//	阈值: 0~2040 (|Gx|+|Gy| 最大 2040), 默认 64, 步长 8
//	SOBEL_MODE_4DIR: 0=|Gx|+|Gy|(赛题要求) 1=四方向取最大(旧方案,可选)
//	按键(核心板丝印K1/K2, 低有效, 1.8V bank1A):
//	  K1 短按 阈值-8, 按住0.5s后每80ms连减
//	  K2 短按 阈值+8, 按住0.5s后每80ms连加
//	  K1+K2 同时按 = 切换算法模式, 循环 0 -> 1 -> 2 -> 0, 上电默认 2:
//	    0 = Sobel 二值边缘
//	    1 = Canny 边缘                          (高阶挑战4)
//	    2 = Canny 边缘 + 简易目标识别叠加显示    (高阶挑战4 + 6)
//	  阈值对两种算法都生效: Sobel 用它二值化; Canny 强阈值 = 阈值, 弱阈值 = 阈值/2
//	sobel_ctrl 在 clk_sys 域, 阈值/模式用 toggle 握手搬到 cmos_pclk 域再给 Sobel/Canny 用
//	【高阶挑战3】同一模块还负责: K1 长按冻结 / K2 长按回放 / 回放翻帧
wire [10:0] sobel_thr_sys;		//clk_sys 域当前阈值
wire [1:0]  sobel_mode_sys;		//clk_sys 域算法模式 0 Sobel / 1 Canny / 2 Canny+识别
wire        sobel_cfg_toggle;	//配置变化标志
wire [1:0]  disp_mode_sys;		//0 实时 / 1 冻结 / 2 回放
wire [6:0]  w_live_slot, w_freeze_slot, w_replay_slot, w_ring_count;
wire        w_live_valid, w_frame_commit, w_underrun;
wire        w_freeze_enter, w_replay_enter, w_step_prev, w_step_next;
wire [6:0]  w_freeze_slot_in;
sobel_ctrl #(
	.THR_DEFAULT(11'd64)		//上电默认阈值: 现场实测按 24 下 K1 最优 -> 256-24*8=64
) u_sobel_ctrl(
	.clk        (clk_sys        ),
	.rst_n      (rstn_sys       ),
	.key1_n     (key1_n         ),
	.key2_n     (key2_n         ),
	.live_slot  (w_live_slot    ),
	.live_valid (w_live_valid   ),
	.frames_ready(w_live_valid && (w_ring_count != 7'd0)),
	.threshold  (sobel_thr_sys  ),
	.mode       (sobel_mode_sys ),
	.cfg_toggle (sobel_cfg_toggle),
	.disp_mode  (disp_mode_sys  ),
	.freeze_enter  (w_freeze_enter  ),
	.freeze_slot_in(w_freeze_slot_in),
	.replay_enter  (w_replay_enter  ),
	.step_prev     (w_step_prev     ),
	.step_next     (w_step_next     )
);
//	LED 指示: led_o[5:4]=显示模式(实时/冻结/回放), led_o[3:0]=阈值档位
assign led_o[5:4] = disp_mode_sys;
assign led_o[3:0] = sobel_thr_sys[10:7];
//	配置跨时钟域: clk_sys -> cmos_pclk, 检测到 toggle 翻转才锁存(此时数据已稳定)
reg        cfg_tog_s1,cfg_tog_s2,cfg_tog_s3;
reg [10:0] sobel_thr_pclk;
reg [1:0]  sobel_mode_pclk;
always@(posedge w_cmos_pclk or negedge rstn_sys)
	if(!rstn_sys)begin
		cfg_tog_s1<=1'b0; cfg_tog_s2<=1'b0; cfg_tog_s3<=1'b0;
		//	这里的复位值只是过渡: sobel_ctrl 上电后会立刻推送一次真正的默认值过来
		sobel_thr_pclk<=11'd256;  sobel_mode_pclk<=2'd2;
	end
	else begin
		cfg_tog_s1<=sobel_cfg_toggle;
		cfg_tog_s2<=cfg_tog_s1;
		cfg_tog_s3<=cfg_tog_s2;
		if(cfg_tog_s2 ^ cfg_tog_s3)begin
			sobel_thr_pclk <=sobel_thr_sys;
			sobel_mode_pclk<=sobel_mode_sys;
		end
	end
wire        sobel_sop, sobel_valid, sobel_eop;
wire [7:0]  sobel_data;
wire [7:0]  sobel_gray;		//与sobel_data同延迟的原图灰度(分屏显示用)
wire [7:0]  sobel_bin;		//二值化边缘(与模式无关, 彩色叠加用)
Sobeledge_8d_proc #(
	.WIDTH(1280),
	.HEIGHT(720),
	.SOBEL_MODE_4DIR(1'b0)
) u_Sobeledge_8d_proc (
	.clk         (w_cmos_pclk),
	.rst_n       (rstn_sys  ),
	.mode        (2'd2            ),	//source_data 显示通路已不用(DDR 只存 source_bin), 固定二值
	.threshold   (sobel_thr_pclk  ),	//二值化阈值(按键控制)
	.sink_sop    (sobel_in_sop  ),
	.sink_eop    (sobel_in_eop  ),
	.sink_valid  (sobel_in_valid),
	.sink_data   (sobel_in_data ),
	.source_sop  (sobel_sop ),
	.source_eop  (sobel_eop ),
	.source_valid(sobel_valid),
	.source_data (sobel_data),
	.source_gray (sobel_gray),
	.source_bin  (sobel_bin )
);

////////////////////////////////////////////////////////////////
//	【高阶挑战4】Canny 边缘检测, 级联在 Sobel 之后
//	输入用 Sobel 输出的 source_gray(中值滤波后的灰度, 与 sobel_bin 逐像素对齐),
//	Sobel 二值结果从 side_in 旁路穿过 Canny 的 4 级窗口, 出来时与 Canny 结果逐像素对齐,
//	所以按键在 Sobel/Canny 之间切换不需要另做延迟对齐, 两路共用同一条彩色延迟线。
//	CANNY_EN=0: 不例化 Canny (省资源/对比实验), 模式 1/2 自动退回 Sobel。
////////////////////////////////////////////////////////////////
localparam CANNY_EN = 1'b1;
wire        edge_sop, edge_eop, edge_valid;
wire        canny_bit, sobel_bit;		//同一时刻、同一像素的 Canny / Sobel 二值结果
generate
	if (CANNY_EN) begin : g_canny
		canny_edge #(
			.WIDTH (1280),
			.HEIGHT(720)
		) u_canny_edge (
			.clk         (w_cmos_pclk     ),
			.rst_n       (rstn_sys        ),
			.th_high     (sobel_thr_pclk  ),
			.th_low      ({1'b0, sobel_thr_pclk[10:1]}),
			.sink_sop    (sobel_sop       ),
			.sink_eop    (sobel_eop       ),
			.sink_valid  (sobel_valid     ),
			.sink_data   (sobel_gray      ),
			.side_in     (sobel_bin[7]    ),
			.source_sop  (edge_sop        ),
			.source_eop  (edge_eop        ),
			.source_valid(edge_valid      ),
			.source_edge (canny_bit       ),
			.side_out    (sobel_bit       )
		);
	end
	else begin : g_no_canny
		assign edge_sop   = sobel_sop;
		assign edge_eop   = sobel_eop;
		assign edge_valid = sobel_valid;
		assign canny_bit  = sobel_bin[7];
		assign sobel_bit  = sobel_bin[7];
	end
endgenerate
//	当前模式选用的二值边缘
wire        edge_bit = (sobel_mode_pclk == 2'd0) ? sobel_bit : canny_bit;
	reg			r_XYCrop_frame_vsync = 0; 
	reg			r_XYCrop_frame_href = 0;
	reg			r_XYCrop_frame_de = 0;
	reg	[63:0]	r_XYCrop_frame_Gray = 0;
	
	always @(posedge w_cmos_pclk) begin
		r_XYCrop_frame_vsync <= XYCrop_frame_vsync; 
		r_XYCrop_frame_href <= XYCrop_frame_href;
		r_XYCrop_frame_de <= XYCrop_frame_de;
		r_XYCrop_frame_Gray <= XYCrop_frame_Gray;
	end
	
	//	Data Write Assignment
	wire			cmos_frame_vsync = r_XYCrop_frame_vsync;                     //  cmos frame data vsync valid signal
	wire			cmos_frame_href = r_XYCrop_frame_href && r_XYCrop_frame_de;	 //  cmos frame data href vaild  signal
	wire	[63:0]	cmos_frame_Gray = r_XYCrop_frame_Gray; 
	wire 			cmos_vsync_end;

	












	////////////////////////////////////////////////////////////////
	//	DDR R/W Control
	//	彩色延迟线(块RAM环形缓冲): 让 RGB565 原图与边缘结果在同一时刻打包进 DDR。
	//
	//	[dyc 改] 原来按"固定延迟 RGB_DLY 个像素"读, RGB_DLY = 窗口序号滞后 + 实测时钟拍数 混算,
	//	         各级窗口自身的几拍时钟延迟没算进去, 行尾 valid 断续时还会漂, 接上 Canny 后误差更大。
	//	现改为按"像素序号"对齐, 与时钟延迟、valid 是否连续都无关:
	//	  * 写侧: 每个输入像素(valid_w0)写一格, 帧首像素(sop_w0)记下它的地址 rgb_base
	//	  * 流水线每一级都是"一进一出", 输出帧第 n 个像素对应输入帧第 n - PIPE_LAG 个像素
	//	    (每级 3x3 窗口序号滞后 WIDTH+1, 见 sim/tb_pipeline_latency.v、sim/tb_canny_edge.v)
	//	  * 读侧: 输出帧首像素时读地址 = rgb_base - PIPE_LAG, 之后每输出一个像素地址 +1
	//	  * 环深 8192 取 2 的幂, 地址减法自然回绕
	//	PIPE_LAG: 中值 1281 + Sobel 1281 + Canny 4*1281 = 7686 (rgb2gray 是纯时钟流水线, 序号滞后 0)
	localparam [31:0] PIPE_LAG = (MEDIAN_EN ? 1281 : 0) + 1281 + (CANNY_EN ? 4*1281 : 0);
	wire [15:0] rgb_dly;
	wire [7:0]  gray_dly;
	wire        pk_valid, pk_sop, pk_eop, pk_edge;		//打包级: 比 edge_* 晚一拍, 与 rgb_dly 同拍
	rgb_align_ring #(
		.AW  (13),			//环深 8192 > 7686 + 在途像素
		.LAG (PIPE_LAG),
		.GRAY_LAG (PIPE_LAG - 1281)		//中值灰度比原图晚一个中值窗口
	) u_rgb_align_ring (
		.clk      (w_cmos_pclk),
		.in_valid (valid_w0   ),
		.in_sop   (sop_w0     ),
		.in_rgb   (data_w0    ),
		.in_gray_valid(med_valid),
		.in_gray_sop  (med_sop  ),
		.in_gray      (med_data ),
		.out_valid(edge_valid ),
		.out_sop  (edge_sop   ),
		.out_eop  (edge_eop   ),
		.out_edge (edge_bit   ),
		.pk_valid (pk_valid   ),
		.pk_sop   (pk_sop     ),
		.pk_eop   (pk_eop     ),
		.pk_edge  (pk_edge    ),
		.pk_rgb   (rgb_dly    ),
		.pk_gray  (gray_dly   )
	);
	//	整帧统一打包(一个像素32bit): {帧首,帧尾,6'h0,中值灰度, RGB555, 二值边缘}
	wire [15:0] wraw_pix  = {rgb_dly[15:11], rgb_dly[10:6], rgb_dly[4:0], pk_edge};
	wire [31:0] wframe_pack = {pk_sop, pk_eop, 6'h00, gray_dly, wraw_pix};

	////////////////////////////////////////////////////////////////
	//	【高阶挑战6】简易目标识别 (模块: src/shape/, 原作者 梁雅萱, lyx 分支)
	//	在写入 DDR 的同一路边缘流上做单遍几何特征统计(包围盒/周长/扫描线填充面积),
	//	帧末按填充率分类: 矩形≈1.0 圆≈0.785 三角形≈0.5。坐标即 DDR/屏幕坐标, 显示端可直接画框。
	//	识别始终在跑(用当前模式选中的边缘), 叠加显示只在模式 2 打开。
	////////////////////////////////////////////////////////////////
	wire [1:0]  shp_shape;
	wire [10:0] shp_x0, shp_x1;
	wire [9:0]  shp_y0, shp_y1;
	wire [23:0] shp_edge_cnt, shp_area;
	wire [15:0] shp_ratio;
	wire        shp_rvalid;
	shape_recognizer #(
		.H_ACTIVE (1280),
		.V_ACTIVE (720),
		.XW       (11),
		.YW       (10),
		.CW       (24),
		.MIN_EDGE (24'd400),		//ROI 内边缘像素少于此数判"未识别"
		.RECT_Q   (16'd230),		//填充率 >= 0.90 -> 矩形
		.CIRC_Q   (16'd168),		//填充率 >= 0.66 -> 圆形
		.TRI_Q    (16'd96),			//填充率 >= 0.38 -> 三角形
		.ROI_X0   (400),			//只统计画面正中 480x360, 排除背景杂波
		.ROI_X1   (879),
		.ROI_Y0   (180),
		.ROI_Y1   (539)
	) u_shape_recognizer (
		.clk          (w_cmos_pclk  ),
		.rst_n        (rstn_sys     ),
		.st_sop       (pk_sop       ),
		.st_eop       (pk_eop       ),
		.st_valid     (pk_valid     ),
		.st_data      ({8{pk_edge}} ),	//已是二值边缘, 扩成 0x00/0xFF
		.thresh       (8'h80        ),
		.roi_en       (1'b1         ),
		.shape        (shp_shape    ),
		.box_x0       (shp_x0       ),
		.box_x1       (shp_x1       ),
		.box_y0       (shp_y0       ),
		.box_y1       (shp_y1       ),
		.feat_edge    (shp_edge_cnt ),
		.feat_area    (shp_area     ),
		.feat_ratio_q (shp_ratio    ),
		.result_valid (shp_rvalid   )
	);
	

	wire                            lcd_de;
	wire                            lcd_hs;      
	wire                            lcd_vs;
	wire 					  lcd_request; 
	wire            [7:0]           lcd_red, lcd_red2;
	wire            [7:0]           lcd_green, lcd_green2;
	wire            [7:0]           lcd_blue, lcd_blue2;
	wire            [15:0]          lcd_data;


	assign w_ddr3_wid = 0; 
	
	wire lcd_line_start, lcd_frame_start;
	wire [11:0] lcd_vcnt;
	wire [15:0] pix_l, pix_r;
	wire        pix_valid, pix_split;
	
	//	【高阶挑战3】DDR3 帧存储: 100 帧环 + 3 个实时 scratch 槽,
	//	显示端按行取数 + 双 bank 行缓存, 冻结/回放时左实时右历史。
	frame_store #(
		.H_ACTIVE(1280), .V_ACTIVE(720),
		.N_RING(100), .N_SCRATCH(3),
		.SLOT_AW(22),			// 4MiB / slot
		.W_BURST(128), .R_BURST(128),
		.V_ACTIVE_START(25)	// 720p: V_SYNC=5 + V_BACK=20
	) u_frame_store (
		.axi_awid       (w_ddr3_awid        ),
		.axi_awaddr     (w_ddr3_awaddr      ),
		.axi_awlen      (w_ddr3_awlen       ),
		.axi_awsize     (w_ddr3_asize       ),
		.axi_awburst    (w_ddr3_aburst      ),
		.axi_awlock     (w_ddr3_alock       ),
		.axi_awcache    (),
		.axi_awprot     (),
		.axi_awqos      (),
		.axi_awvalid    (w_ddr3_awvalid     ),
		.axi_awready    (w_ddr3_awready     ),

		.axi_wdata      (w_ddr3_wdata       ),
		.axi_wstrb      (w_ddr3_wstrb       ),
		.axi_wlast      (w_ddr3_wlast       ),
		.axi_wvalid     (w_ddr3_wvalid      ),
		.axi_wready     (w_ddr3_wready      ),

		.axi_bid        (w_ddr3_bid         ),
		.axi_bresp      (w_ddr3_bresp       ),
		.axi_bvalid     (w_ddr3_bvalid      ),
		.axi_bready     (w_ddr3_bready      ),

		.axi_arid       (w_ddr3_arid        ),
		.axi_araddr     (w_ddr3_araddr      ),
		.axi_arlen      (w_ddr3_arlen       ),
		.axi_arsize     (w_ddr3_asize       ),
		.axi_arburst    (w_ddr3_aburst      ),
		.axi_arlock     (w_ddr3_alock       ),
		.axi_arcache    (),
		.axi_arprot     (),
		.axi_arqos      (),
		.axi_arvalid    (w_ddr3_arvalid     ),
		.axi_arready    (w_ddr3_arready     ),

		.axi_rid        (w_ddr3_rid         ),
		.axi_rdata      (w_ddr3_rdata       ),
		.axi_rresp      (w_ddr3_rresp       ),
		.axi_rlast      (w_ddr3_rlast       ),
		.axi_rvalid     (w_ddr3_rvalid      ),
		.axi_rready     (w_ddr3_rready      ),

		.axi_clk        (w_ddr3_ui_clk      ),
		.axi_reset      (w_ddr3_ui_rst      ),
		.ddr_ready      (r_ddr_unlock       ),

		.wclk           (w_cmos_pclk        ),
		.wrst           (~rstn_sys          ),
		.wvalid         (pk_valid           ),
		.wsop           (pk_sop             ),
		.weop           (pk_eop             ),
		.wraw           (wraw_pix           ),
		.wgray          (gray_dly           ),

		.ctrl_mode      (disp_mode_sys      ),
		.freeze_enter   (w_freeze_enter     ),
		.freeze_slot_in (w_freeze_slot_in   ),
		.replay_enter   (w_replay_enter     ),
		.step_prev      (w_step_prev        ),
		.step_next      (w_step_next        ),
		.live_slot_o    (w_live_slot        ),
		.freeze_slot_o  (w_freeze_slot      ),
		.replay_slot_o  (w_replay_slot      ),
		.ring_count_o   (w_ring_count       ),
		.live_valid_o   (w_live_valid       ),
		.frame_commit_o (w_frame_commit     ),
		.underrun_o     (w_underrun         ),

		.pclk           (clk_pixel          ),
		.prst           (rst_pixel          ),
		.lcd_line_start (lcd_line_start     ),
		.lcd_frame_start(lcd_frame_start    ),
		.lcd_vcnt       (lcd_vcnt           ),
		.lcd_request    (lcd_request        ),
		.lcd_xpos       (lcd_xpos           ),
		.pix_l          (pix_l              ),
		.pix_r          (pix_r              ),
		.pix_valid      (pix_valid          ),
		.pix_split      (pix_split          )
	);
	
	
	
	
	////////////////////////////////////////////////////////////////
	//  LCD Timing Driver
	//	【高阶挑战3】显示合成:
	//	  实时模式 : 左 640 列 = 彩色原图+红色 Canny 边缘 + 目标框/标签,
	//	             右 640 列 = Canny 二值边缘 (与旧版默认一致)
	//	  冻结/回放: 左 640 列 = 实时原始彩色, 右 640 列 = 冻结/历史原始彩色,
	//	             两个源都按 2x2 抽样成 640x360, 上下留黑边
	//	  帧存储 pix_l = {RGB555,edge}, pix_r = {8'h0,median_gray}
	wire 	[11:0] 	lcd_xpos, lcd_ypos;
	localparam LIVE_SPLIT = 1'b1;		//1=实时左右分屏(左彩色+红边/右二值)  0=整屏二值
	wire 	[23:0] 	lcd_col_l = {pix_l[15:11], pix_l[13:11],	// R5 -> R8
	                             pix_l[10:6],  pix_l[8:6],	// G5 -> G8
	                             pix_l[5:1],   pix_l[3:1]};	// B5 -> B8
	wire 	[23:0] 	lcd_col_r = {pix_r[15:11], pix_r[13:11],
	                             pix_r[10:6],  pix_r[8:6],
	                             pix_r[5:1],   pix_r[3:1]};
	wire 	[23:0] 	lcd_live_col = pix_l[0] ? 24'hFF0000 : lcd_col_l;
	wire 	[23:0] 	lcd_live_bin = pix_l[0] ? 24'hFFFFFF : 24'h000000;
	//	实时: 左彩色+红边 / 右二值;  冻结/回放: 左右都是原始彩色
	wire 	[23:0] 	lcd_pixel = !pix_valid ? 24'h000000 :
	                           (pix_split ? ((lcd_xpos < 12'd640) ? lcd_col_l : lcd_col_r)
	                                      : ((LIVE_SPLIT && (lcd_xpos < 12'd640)) ? lcd_live_col
	                                                                              : lcd_live_bin));

	////////////////////////////////////////////////////////////////
	//	【高阶挑战6】识别结果 跨时钟域(w_cmos_pclk -> clk_pixel) + 屏幕叠加
	//	结果每帧只更新一次且保持一整帧, 用电平翻转握手传递
	////////////////////////////////////////////////////////////////
	wire [1:0]  disp_shape;
	wire [10:0] disp_x0, disp_x1;
	wire [9:0]  disp_y0, disp_y1;
	wire [15:0] disp_ratio;
	wire        disp_svalid;
	shape_result_cdc #(.XW(11), .YW(10)) u_shape_result_cdc (
		.clk_a   (w_cmos_pclk ),
		.rst_a_n (rstn_sys    ),
		.load    (shp_rvalid  ),
		.shape_a (shp_shape   ),
		.x0_a    (shp_x0      ),
		.x1_a    (shp_x1      ),
		.y0_a    (shp_y0      ),
		.y1_a    (shp_y1      ),
		.ratio_a (shp_ratio   ),
		.clk_b   (clk_pixel   ),
		.rst_b_n (rstn_pixel  ),
		.shape_b (disp_shape  ),
		.x0_b    (disp_x0     ),
		.x1_b    (disp_x1     ),
		.y0_b    (disp_y0     ),
		.y1_b    (disp_y1     ),
		.ratio_b (disp_ratio  ),
		.valid_b (disp_svalid )
	);
	//	模式2 且实时显示才叠加目标框/标签: 模式是准静态电平, 两级同步即可
	reg  [1:0]  ov_en_sync = 2'b00;
	reg  [1:0]  live_sync  = 2'b00;
	always @(posedge clk_pixel) ov_en_sync <= {ov_en_sync[0], (sobel_mode_sys == 2'd2)};
	always @(posedge clk_pixel) live_sync  <= {live_sync[0],  (disp_mode_sys   == 2'd0)};
	wire        ov_en = ov_en_sync[1] & live_sync[1];
	wire [23:0] lcd_ov;
	shape_overlay #(
		.S         (2),		//文字放大 2 倍, 每个汉字 32x32
		.X_SHIFT   (0),		//FWFT 读 FIFO, lcd_xpos 已等于图像列号(lyx 原版取 1 会偏一列)
		.LABEL_X   (24),
		.LABEL_Y   (24),
		.BOX_THICK (2)
	) u_shape_overlay (
		.clk   (clk_pixel   ),
		.rst_n (rstn_pixel  ),
		.de    (lcd_request & ov_en),
		.xpos  (lcd_xpos    ),
		.ypos  (lcd_ypos    ),
		.base  (lcd_pixel   ),
		.shape (disp_shape  ),
		.bx0   ({1'b0, disp_x0}),
		.bx1   ({1'b0, disp_x1}),
		.by0   ({2'b0, disp_y0}),
		.by1   ({2'b0, disp_y1}),
		.valid (disp_svalid ),
		.rgb   (lcd_ov      )
	);
	wire 	[7:0] 	lcd_data_r = lcd_ov[23:16];
	wire 	[7:0] 	lcd_data_g = lcd_ov[15:8];
	wire 	[7:0] 	lcd_data_b = lcd_ov[7:0];
	
	lcd_driver u_lcd_driver
	(
	    //  global clock
	    .clk        (clk_pixel   ),
	    .rst_n      (rstn_pixel), 
	    
	    //  lcd interface
	    .lcd_dclk   (               ),
	    .lcd_blank  (               ),
	    .lcd_sync   (               ),
	    .lcd_request(lcd_request    ), 	//	Request data 1 cycle ahead. 
	    .lcd_hs     (lcd_hs         ),
	    .lcd_vs     (lcd_vs         ),
	    .lcd_en     (lcd_de         ),
	    .lcd_rgb    ({lcd_red2,lcd_green2,lcd_blue2, lcd_red,lcd_green,lcd_blue}),
	    .lcd_xpos   (lcd_xpos),	//	用于分屏判断左右半屏 / 叠加层定位
	    .lcd_ypos   (lcd_ypos),	//	叠加层定位
	    .lcd_line_start (lcd_line_start),
	    .lcd_frame_start(lcd_frame_start),
	    .lcd_vcnt       (lcd_vcnt       ),
	    
	    //  user interface
	    .lcd_data   ({lcd_data_r, lcd_data_g, lcd_data_b}  )
	);
	
	
	
	////////////////////////////////////////////////////////////////
	//	HDMI Interface. 
	
	//	HDMI requires specific timing, thus is not compatible with LCD & LVDS & DSI. Must implement standalone. 
	
	assign hdmi_txd0_rst_o = rst_pixel; 
	assign hdmi_txd1_rst_o = rst_pixel; 
	assign hdmi_txd2_rst_o = rst_pixel; 
	assign hdmi_txc_rst_o = rst_pixel; 
	
	assign hdmi_txd0_oe = 1'b1; 
	assign hdmi_txd1_oe = 1'b1; 
	assign hdmi_txd2_oe = 1'b1; 
	assign hdmi_txc_oe = 1'b1; 
	
	//-------------------------------------
	//Digilent HDMI-TX IP Modified by CB elec.
	rgb2dvi #(.ENABLE_OSERDES(0)) u_rgb2dvi 
	(
		//.TMDS_Clk_p		(hdmio_txc_p_o), 	//	w_hdmio_txc), 
		//.TMDS_Clk_n		(hdmio_txc_n_o), 
		//.TMDS_Data_p	(hdmio_txd_p_o), 	//	w_hdmio_txd), 
		//.TMDS_Data_n 	(hdmio_txd_n_o), 
		
		.oe_i 		(1), 			//	Always enable output
		.bitflip_i 		(4'b0000), 		//	Reverse clock & data lanes. 
		
		.aRst			(1'b0), 
		.aRst_n		(1'b1), 
		
		.PixelClk		(clk_pixel        ),//pixel clk = 74.25M
		.SerialClk		(     ),//pixel clk *5 = 371.25M
		
		.vid_pVSync		(lcd_vs), 
		.vid_pHSync		(lcd_hs), 
		.vid_pVDE		(lcd_de), 
		.vid_pData		({lcd_red, lcd_green, lcd_blue}), 
		
		.txc_o			(hdmi_txc_o), 
		.txd0_o			(hdmi_txd0_o), 
		.txd1_o			(hdmi_txd1_o), 
		.txd2_o			(hdmi_txd2_o)
	); 
		
	






	
	
endmodule


