//==============================================================================
//  shape_result_cdc.v
//  ---------------------------------------------------------------------------
//  识别结果跨时钟域传递：摄像头像素时钟 (cmos_pclk)  ->  显示像素时钟 (clk_pixel)
//
//  识别结果每帧只更新一次，更新后至少保持一整帧时间(~16.7ms)不变，
//  因此采用「数据先锁存、再用电平翻转标志做握手」的经典做法：
//      * 源端：load 有效时把 target_count 与整条目标结果总线一起打进 *_s
//              寄存器，同时翻转 tog
//      * 目的端：tog 经两级触发器同步后做边沿检测，边沿到来时把稳定的 *_s
//                数据整体打入 *_b 寄存器
//  数据在 tog 翻转前已经稳定，且在下一次翻转前不会变化，因此不存在
//  多比特同时跳变带来的亚稳态/数据撕裂问题，也无需多周期路径约束。
//
//  全部目标共用一次翻转握手（不为每个目标单独做 CDC）：目标数与结果总线
//  总是同一帧、同一时刻整体搬运，显示端看到的永远是完整的一帧结果。
//  target_count = 0 也是有效结果，同样会更新一次，绝不会残留上一帧目标。
//==============================================================================
`timescale 1ns/1ps

module shape_result_cdc #(
    parameter MAX_TARGETS = 4,      // 一帧最多目标数
    parameter TBW         = 80,     // 单目标结果位宽
    parameter TCNT_W      = 4       // target_count 位宽
)(
    // ---------------- 源端：摄像头像素时钟域 ----------------
    input  wire             clk_a,
    input  wire             rst_a_n,
    input  wire             load,           // 单周期脉冲，指示结果已稳定
    input  wire [TCNT_W-1:0]         count_a,
    input  wire [MAX_TARGETS*TBW-1:0] targets_a,

    // ---------------- 目的端：显示像素时钟域 ----------------
    input  wire             clk_b,
    input  wire             rst_b_n,
    output reg  [TCNT_W-1:0]         count_b,
    output reg  [MAX_TARGETS*TBW-1:0] targets_b,
    output reg              valid_b         // 新结果到达的单周期脉冲
);

    // ---------------- 源端：整体锁存 + 翻转 ----------------
    reg [TCNT_W-1:0]         count_s;
    reg [MAX_TARGETS*TBW-1:0] targets_s;
    reg                      tog_s;

    always @(posedge clk_a or negedge rst_a_n) begin
        if (!rst_a_n) begin
            count_s   <= {TCNT_W{1'b0}};
            targets_s <= {MAX_TARGETS*TBW{1'b0}};
            tog_s     <= 1'b0;
        end else if (load) begin
            count_s   <= count_a;
            targets_s <= targets_a;
            tog_s     <= ~tog_s;
        end
    end

    // ---------------- 目的端：两级同步 + 边沿检测 ----------------
    reg tog_meta, tog_sync, tog_sync_d;

    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) begin
            tog_meta   <= 1'b0;
            tog_sync   <= 1'b0;
            tog_sync_d <= 1'b0;
        end else begin
            tog_meta   <= tog_s;
            tog_sync   <= tog_meta;
            tog_sync_d <= tog_sync;
        end
    end

    wire new_result = (tog_sync ^ tog_sync_d);   // 任一边沿都表示有新结果

    always @(posedge clk_b or negedge rst_b_n) begin
        if (!rst_b_n) begin
            count_b   <= {TCNT_W{1'b0}};
            targets_b <= {MAX_TARGETS*TBW{1'b0}};
            valid_b   <= 1'b0;
        end else begin
            valid_b <= new_result;
            if (new_result) begin
                count_b   <= count_s;
                targets_b <= targets_s;
            end
        end
    end

endmodule
