`timescale 1ns/1ps
module tb_rgb2gray_probe;

reg clk = 0;
reg rst_n = 0;
always #5 clk = ~clk;

reg sop = 0, valid = 0, eop = 0;
reg [23:0] rgb = 0;
wire osop, ovalid, oeop;
wire [7:0] gray;

vip_rgb2gray_proc #(.BPS(8)) dut (
	.clk(clk), .rst_n(rst_n),
	.sink_sop(sop), .sink_valid(valid), .sink_eop(eop), .sink_data(rgb),
	.source_sop(osop), .source_valid(ovalid), .source_eop(oeop),
	.source_data(gray)
);

integer n = 0;
integer errors = 0;
integer expected [0:3];
initial begin
	expected[0] = 0;
	expected[1] = 226;
	expected[2] = 44;
	expected[3] = 255;
end

always @(posedge clk) begin
	if (rst_n && ovalid) begin
		if (n > 3) begin
			$display(" unexpected extra output[%0d]=%0d", n, gray);
			errors = errors + 1;
		end else begin
			$display(" gray[%0d]=%0d expect=%0d", n, gray, expected[n]);
			if (gray !== expected[n])
				errors = errors + 1;
		end
		n = n + 1;
	end
end

initial begin
	repeat(10) @(posedge clk);
	rst_n = 1;
	repeat(5) @(posedge clk);
	@(negedge clk); sop = 1; valid = 1; rgb = 24'h000000; eop = 0;
	@(negedge clk); sop = 0; rgb = 24'hFFFF07; // expanded RGB565 0xffe0
	@(negedge clk); rgb = 24'h2F2B2F;          // expanded RGB565 0x2945
	@(negedge clk); rgb = 24'hFFFFFF; eop = 1;
	@(negedge clk); valid = 0; eop = 0;
	repeat(30) @(posedge clk);
	if ((n == 4) && (errors == 0))
		$display(" RESULT: ALL CHECKS PASSED");
	else begin
		$display(" RESULT: %0d CHECK(S) FAILED, outputs=%0d", errors, n);
		errors = errors + 1;
	end
	$finish;
end

initial begin
	#100000;
	$display(" TIMEOUT outputs=%0d", n);
	$finish;
end

endmodule
