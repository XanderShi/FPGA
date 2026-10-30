//==============================================================================
//  shape_overlay.v
//  ---------------------------------------------------------------------------
//  识别结果显示叠加层（赛题四 高阶挑战 3：多目标同时显示）
//
//  工作在显示像素时钟域 (clk_pixel)，在 LCD/HDMI 输出通路上实时叠加：
//      1) 每个有效目标画一个独立彩色矩形框 (圆形青 / 矩形绿 / 三角形黄)
//      2) 每个框附近显示对应的中文标签「圆形」「矩形」「三角形」
//         标签优先放在框的上方; 上方空间不足时放在框内左上角
//      3) 没有目标时, 在画面左上角显示原来的「未识别」提示
//
//  中文点阵取自 font_cn_rom.v（16x16 宋体，共 13 个字模）。
//  文字按 S 倍放大，S 必须是 2 的幂(1/2/4)，这样字模寻址只需移位和掩码，
//  完全不消耗除法器或乘法器资源。
//
//  叠加层不关心底图是怎么来的：它接收显示端已经算好的 24bit RGB888（base），
//  只对命中像素改写颜色。因此无论是纯灰度图、队友的分屏彩色叠加结果，
//  都不需要改动 DDR 帧缓存的数据宽度。
//
//  绘制优先级(与单目标版本一致): 文字 > 底板 > 包围框 > 底图。
//  多个目标互相遮挡时按目标序号(0 最小)优先, 同一帧内完全确定, 不会闪烁。
//  所有坐标都先做边界保护再比较, 负坐标用加宽无符号比较, 不会画到屏幕别处。
//==============================================================================
`timescale 1ns/1ps

module shape_overlay #(
    parameter S           = 2,      // 文字放大倍数，必须是 2 的幂：1/2/4
    parameter X_SHIFT     = 0,      // lcd_xpos 与图像列号的偏移
    parameter LABEL_X     = 24,     // 「未识别」提示左上角（图像坐标）
    parameter LABEL_Y     = 24,
    parameter PAD         = 6,      // 文字底板外扩
    parameter BOX_THICK   = 2,      // 包围盒线宽
    parameter MAX_TARGETS = 4,      // 与 shape_recognizer 一致
    parameter TBW         = 80,     // 单目标结果位宽, 见 shape_recognizer 头注释
    parameter XW          = 11,
    parameter YW          = 10,
    parameter TCNT_W      = 4,
    parameter H_ACTIVE    = 1280,
    parameter V_ACTIVE    = 720
)(
    input  wire         clk,
    input  wire         rst_n,

    // 显示像素流（来自 lcd_driver / DDR 读回）
    input  wire         de,             // 数据有效
    input  wire [11:0]  xpos,           // lcd_driver 输出的列坐标
    input  wire [11:0]  ypos,           // lcd_driver 输出的行坐标
    input  wire [23:0]  base,           // 底图 RGB888（分屏/彩色叠加后的结果）

    // 来自 shape_result_cdc 的多目标识别结果（显示时钟域）
    input  wire [TCNT_W-1:0]          target_count,   // 有效目标数
    input  wire [MAX_TARGETS*TBW-1:0] targets,        // 扁平打包的目标结果
    input  wire                       valid,          // 新结果到达脉冲

    output reg  [23:0]  rgb             // 叠加后的 RGB888
);

    localparam GSZ = 16 * S;                        // 单个字模的像素尺寸
    localparam SLG = (S == 1) ? 0 : ((S == 2) ? 1 : 2);   // log2(S)

    //--------------------------------------------------------------------------
    // 1. 结果有效标志（粘滞）+ 坐标对齐
    //--------------------------------------------------------------------------
    reg have_result;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            have_result <= 1'b0;
        else if (valid)        have_result <= 1'b1;
    end

    wire [11:0] px = xpos - X_SHIFT;
    wire [11:0] py = ypos;

    // 目标数截断保护: 万一同步过程中读到中间值也不会越界绘制
    wire [TCNT_W-1:0] n_tgt = (target_count > MAX_TARGETS) ? MAX_TARGETS : target_count;

    wire en = de && have_result;

    //--------------------------------------------------------------------------
    // 2. 目标结果总线字段偏移（与 shape_recognizer 的打包顺序一致）
    //--------------------------------------------------------------------------
    localparam TB_O_SHAPE = 0;
    localparam TB_O_X0    = TB_O_SHAPE + 2;
    localparam TB_O_X1    = TB_O_X0 + XW;
    localparam TB_O_Y0    = TB_O_X1 + XW;
    localparam TB_O_Y1    = TB_O_Y0 + YW;
    localparam TB_O_RATIO = TB_O_Y1 + YW;
    localparam TB_O_EDGE  = TB_O_RATIO + 16;

    //--------------------------------------------------------------------------
    // 3. 每个目标的包围盒 / 标签几何（组合逻辑, generate 拆包）
    //--------------------------------------------------------------------------
    wire [MAX_TARGETS-1:0]    t_act_v;      // 该槽有效
    wire [MAX_TARGETS-1:0]    t_txt_v;      // 命中该目标的文字像素
    wire [MAX_TARGETS-1:0]    t_pan_v;      // 命中该目标的文字底板
    wire [MAX_TARGETS-1:0]    t_bdr_v;      // 命中该目标的包围框
    wire [MAX_TARGETS*4-1:0]  t_gl_v;       // 字模编号
    wire [MAX_TARGETS*4-1:0]  t_grow_v;     // 字模行
    wire [MAX_TARGETS*4-1:0]  t_gcol_v;     // 字模列
    wire [MAX_TARGETS*24-1:0] t_col_v;      // 类别颜色

    // (shape, 该提示的第几个字) -> font_cn_rom 字模编号
    //   圆形  : 圆(3) 形(4)
    //   矩形  : 矩(5) 形(4)
    //   三角形: 三(9) 角(10) 形(4)
    //   {shape, char_idx} = shape*16 + char_idx, 与旧版提示语用的是同一套编码
    function [3:0] label_glyph;
        input [1:0] sh;
        input [3:0] ci;
        begin
            case ({sh, ci})
                6'd16:   label_glyph = 4'd3;    // 圆形 0 -> 圆
                6'd17:   label_glyph = 4'd4;    // 圆形 1 -> 形
                6'd32:   label_glyph = 4'd5;    // 矩形 0 -> 矩
                6'd33:   label_glyph = 4'd4;    // 矩形 1 -> 形
                6'd48:   label_glyph = 4'd9;    // 三角形 0 -> 三
                6'd49:   label_glyph = 4'd10;   // 三角形 1 -> 角
                6'd50:   label_glyph = 4'd4;    // 三角形 2 -> 形
                default: label_glyph = 4'd4;
            endcase
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < MAX_TARGETS; gi = gi + 1) begin : g_tgt
            wire [1:0]    t_shape = targets[gi*TBW + TB_O_SHAPE +: 2];
            wire [XW-1:0] t_x0    = targets[gi*TBW + TB_O_X0    +: XW];
            wire [XW-1:0] t_x1    = targets[gi*TBW + TB_O_X1    +: XW];
            wire [YW-1:0] t_y0    = targets[gi*TBW + TB_O_Y0    +: YW];
            wire [YW-1:0] t_y1    = targets[gi*TBW + TB_O_Y1    +: YW];

            // 12bit 图像坐标
            wire [11:0] c_x0 = {{(12-XW){1'b0}}, t_x0};
            wire [11:0] c_x1 = {{(12-XW){1'b0}}, t_x1};
            wire [11:0] c_y0 = {{(12-YW){1'b0}}, t_y0};
            wire [11:0] c_y1 = {{(12-YW){1'b0}}, t_y1};

            wire t_act = en && (gi < n_tgt);

            // ---- 包围盒边框 ----
            wire t_in_box = t_act && (px >= c_x0) && (px <= c_x1) &&
                                     (py >= c_y0) && (py <= c_y1);
            // in_box 已保证不欠位, 减法不会下溢
            wire t_border = t_in_box &&
                            (((px - c_x0) < BOX_THICK) || ((c_x1 - px) < BOX_THICK) ||
                             ((py - c_y0) < BOX_THICK) || ((c_y1 - py) < BOX_THICK));

            // ---- 标签几何: 字数 * 字宽 ----
            wire [3:0]  t_nch = (t_shape == 2'd3) ? 4'd3 : 4'd2;   // 三角形 3 字
            wire [11:0] t_lw  = t_nch * GSZ;

            // 上方空间够就放在框上方, 否则放在框内左上角
            wire        t_above = ({1'b0, c_y0} >= (GSZ + PAD));
            wire [11:0] t_ly_raw = t_above ? (c_y0 - GSZ - PAD) : (c_y0 + BOX_THICK);
            // 下边界保护
            wire [12:0] t_bot = {1'b0, t_ly_raw} + GSZ + PAD;
            wire [11:0] t_ly  = (t_bot > V_ACTIVE) ?
                                ((V_ACTIVE > (GSZ + PAD)) ? (V_ACTIVE - GSZ - PAD) : 12'd0) :
                                t_ly_raw;

            // 右边界保护
            wire [12:0] t_rgt = {1'b0, c_x0} + t_lw + PAD;
            wire [11:0] t_lx  = (t_rgt > H_ACTIVE) ?
                                ((H_ACTIVE > (t_lw + PAD)) ? (H_ACTIVE - t_lw - PAD) : 12'd0) :
                                c_x0;

            // ---- 文字命中 ----
            wire [11:0] t_txr  = px - t_lx;
            wire        t_in_t = t_act && (px >= t_lx) && (px < t_lx + t_lw) &&
                                 (py >= t_ly) && (py < t_ly + GSZ);
            wire [3:0]  t_char = t_txr >> (4 + SLG);
            wire [3:0]  t_gcol = (t_txr >> SLG) & 4'hF;
            wire [3:0]  t_grow = ((py - t_ly) >> SLG) & 4'hF;
            wire        t_txt  = t_in_t && (t_char < t_nch);

            // ---- 文字底板 (按字数收放, 用加宽比较避免负坐标下溢) ----
            wire        t_pan = t_act &&
                                ({1'b0, px} + PAD >= {1'b0, t_lx}) &&
                                ({1'b0, px} < {1'b0, t_lx} + t_lw + PAD) &&
                                ({1'b0, py} + PAD >= {1'b0, t_ly}) &&
                                ({1'b0, py} < {1'b0, t_ly} + GSZ + PAD);

            // ---- 类别配色 ----
            wire [23:0] t_col = (t_shape == 2'd1) ? 24'h00FFFF :   // 圆形   青
                                (t_shape == 2'd2) ? 24'h00FF00 :   // 矩形   绿
                                (t_shape == 2'd3) ? 24'hFFFF00 :   // 三角形 黄
                                                    24'hFF4040;

            assign t_act_v [gi]         = t_act;
            assign t_txt_v [gi]         = t_txt;
            assign t_pan_v [gi]         = t_pan;
            assign t_bdr_v [gi]         = t_border;
            assign t_gl_v  [gi*4 +: 4]  = label_glyph(t_shape, t_char);
            assign t_grow_v[gi*4 +: 4]  = t_grow;
            assign t_gcol_v[gi*4 +: 4]  = t_gcol;
            assign t_col_v [gi*24 +: 24] = t_col;
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 4. 无目标时的「未识别」提示（沿用原来的位置和样式）
    //--------------------------------------------------------------------------
    wire no_tgt = (n_tgt == {TCNT_W{1'b0}});

    wire [11:0] u_txr = px - LABEL_X;
    wire        u_in_t = en && no_tgt &&
                         (px >= LABEL_X) && (px < LABEL_X + 3*GSZ) &&
                         (py >= LABEL_Y) && (py < LABEL_Y + GSZ);
    wire [3:0]  u_char = u_txr >> (4 + SLG);
    wire [3:0]  u_gcol = (u_txr >> SLG) & 4'hF;
    wire [3:0]  u_grow = ((py - LABEL_Y) >> SLG) & 4'hF;
    wire        u_txt  = u_in_t && (u_char < 3);
    // 未(6) 识(7) 别(8)
    wire [3:0]  u_gl   = (u_char == 4'd0) ? 4'd6 :
                         (u_char == 4'd1) ? 4'd7 : 4'd8;

    wire [11:0] u_panel_w = 3 * GSZ;
    wire        u_pan = en && no_tgt &&
                        ({1'b0, px} + PAD >= LABEL_X) &&
                        ({1'b0, px} < LABEL_X + u_panel_w + PAD) &&
                        ({1'b0, py} + PAD >= LABEL_Y) &&
                        ({1'b0, py} < LABEL_Y + GSZ + PAD);

    //--------------------------------------------------------------------------
    // 5. 绘制优先级仲裁
    //    同一类里目标序号小的优先(低编号最后赋值 -> 覆盖高编号), 完全确定;
    //    文字 > 底板 > 包围框 > 底图 由输出级保证。
    //--------------------------------------------------------------------------
    reg         win_txt, win_pan, win_bdr;
    reg [3:0]   win_gl, win_grow, win_gcol;
    reg [23:0]  win_col;

    integer k;
    always @(*) begin
        win_txt  = 1'b0;
        win_pan  = 1'b0;
        win_bdr  = 1'b0;
        win_gl   = 4'd0;
        win_grow = 4'd0;
        win_gcol = 4'd0;
        win_col  = 24'hFF4040;

        // 「未识别」提示（目标数 0 时唯一显示内容）
        if (u_txt) begin
            win_txt  = 1'b1;
            win_gl   = u_gl;
            win_grow = u_grow;
            win_gcol = u_gcol;
            win_col  = 24'hFF4040;
        end
        if (u_pan) begin
            win_pan = 1'b1;
            win_col = 24'hFF4040;
        end

        // 多目标: 从大到小赋值, 序号 0 最后赋值 -> 优先级最高
        for (k = MAX_TARGETS - 1; k >= 0; k = k - 1) begin
            if (t_pan_v[k]) begin
                win_pan = 1'b1;
                win_col = t_col_v[k*24 +: 24];
            end
            if (t_bdr_v[k]) begin
                win_bdr = 1'b1;
                win_col = t_col_v[k*24 +: 24];
            end
            if (t_txt_v[k]) begin
                win_txt  = 1'b1;
                win_gl   = t_gl_v  [k*4 +: 4];
                win_grow = t_grow_v[k*4 +: 4];
                win_gcol = t_gcol_v[k*4 +: 4];
                win_col  = t_col_v [k*24 +: 24];
            end
        end
    end

    //--------------------------------------------------------------------------
    // 6. 字模查表
    //--------------------------------------------------------------------------
    wire [15:0] font_bits;
    font_cn_rom u_font_cn_rom (
        .char_idx (win_gl),
        .row      (win_grow),
        .bits     (font_bits)
    );

    wire text_pix = win_txt && font_bits[15 - win_gcol];

    //--------------------------------------------------------------------------
    // 7. 叠加输出（优先级：文字 > 底板 > 边框 > 底图）
    //--------------------------------------------------------------------------
    always @(*) begin
        if (!en)
            rgb = base;
        else if (text_pix)
            rgb = win_col;
        else if (win_pan)
            rgb = 24'h101018;
        else if (win_bdr)
            rgb = win_col;
        else
            rgb = base;
    end

endmodule
