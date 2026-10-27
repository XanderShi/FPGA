@echo off
rem ====================================================================
rem  Unit + system simulation (ModelSim), no Efinity IP model needed.
rem  Canny test needs Python 3 for the golden model (canny_model.py).
rem  NOTE: keep this file ASCII only - Chinese text inside a .bat breaks
rem        cmd.exe parsing under the GBK code page.
rem ====================================================================
pushd "%~dp0"

set SRC=..\src\Sobeledge_8d\hdl
set GRAY=..\src\vip_rgb2gray\hdl

vlib work
vlog -work work +define+DYC_FRAME_STUB_FIFOS +incdir+..\src %SRC%\shift_regs.v %SRC%\extract_region_c_shiftram_xtap.v %SRC%\Sobeledge_matrix_3x3.v %SRC%\Sobeledge_proc.v ..\src\sobel_ctrl.v ..\src\frame_ring_ctrl.v ..\src\median_3x3.v ..\src\canny\canny_edge.v ..\src\rgb_align_ring.v ..\src\shape\shape_recognizer.v ..\src\shape\shape_overlay.v ..\src\shape\font_cn_rom.v ..\src\lcd_driver.v %GRAY%\vip_rgb2gray_proc.v %GRAY%\vip_rgb2gray_mult.v %GRAY%\vip_rgb2gray_shift_regs.v %GRAY%\multiplier_unsigned_16x16_pp.v ref\ref_shiftram_xtap.v tb_Sobeledge_8d_proc.v tb_rgb2gray_probe.v tb_sobel_ctrl.v tb_frame_ring_ctrl.v tb_frame_ring_read.v tb_frame_e2e.v tb_frame_write_stream.v tb_frame_burst32.v tb_median_3x3.v tb_linebuf_equiv.v tb_matrix_gap.v tb_pipeline_latency.v tb_canny_edge.v tb_shape_recognizer.v tb_edge_system.v tb_display_overlay.v

if errorlevel 1 goto compile_error

echo ===== 1 : Sobeledge_8d_proc (algorithm + threshold) =====
vsim -c -do "run -all; quit -f" work.tb_Sobeledge_8d_proc
echo ===== 1b : RGB565 to grayscale =====
vsim -c -do "run -all; quit -f" work.tb_rgb2gray_probe
echo ===== 2 : sobel_ctrl (keys) =====
vsim -c -do "run -all; quit -f" work.tb_sobel_ctrl
echo ===== 2b : frame ring / freeze / replay policy =====
vsim -c -do "run -all; quit -f" work.tb_frame_ring_ctrl
echo ===== 2c : dual-source display read order =====
vsim -c -do "run -all; quit -f" work.tb_frame_ring_read
echo ===== 2d : frame write -> DDR -> display read =====
vsim -c -do "run -all; quit -f" work.tb_frame_e2e
echo ===== 2e : streaming camera frame -> DDR write =====
vsim -c -do "run -all; quit -f" work.tb_frame_write_stream
echo ===== 2f : 32-beat DDR read burst =====
vsim -c -do "run -all; quit -f" work.tb_frame_burst32
echo ===== 3 : median_3x3 =====
vsim -c -do "run -all; quit -f" work.tb_median_3x3
echo ===== 4 : line buffer BRAM vs shift chain =====
vsim -c -do "run -all; quit -f" work.tb_linebuf_equiv
echo ===== 5 : 3x3 window with valid gaps =====
vsim -c -do "run -all; quit -f" work.tb_matrix_gap
echo ===== 6 : median+Sobel latency =====
vsim -c -do "run -all; quit -f" work.tb_pipeline_latency
echo ===== 7 : Canny vs golden model (continuous + gappy valid) =====
python canny_model.py gen 64 48 160 80 .
vsim -c -do "run -all; quit -f" work.tb_canny_edge
python canny_model.py check .
vsim -c -G GAPPY=1 -do "run -all; quit -f" work.tb_canny_edge
python canny_model.py check .
echo ===== 8 : shape_recognizer =====
vsim -c -do "run -all; quit -f" work.tb_shape_recognizer
echo ===== 9 : system, 1280 wide (slow, several minutes each) =====
vsim -c -G IMG=0 -do "run -all; quit -f" work.tb_edge_system
vsim -c -G IMG=1 -G MODE=1 -do "run -all; quit -f" work.tb_edge_system
vsim -c -G IMG=1 -G MODE=0 -do "run -all; quit -f" work.tb_edge_system
echo ===== 10 : display overlay (writes overlay.ppm) =====
vsim -c -do "run -all; quit -f" work.tb_display_overlay
goto end

:compile_error
echo.
echo *** COMPILE FAILED, see the errors above ***

:end
popd
pause
