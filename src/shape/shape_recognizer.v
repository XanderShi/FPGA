//==============================================================================
//  shape_recognizer.v
//  ---------------------------------------------------------------------------
//  简易目标识别 - 几何特征提取与形状分类 (赛题四 高阶挑战 6)
//
//  在 Sobel 边缘检测结果的基础上，对每一帧做单遍(pass)统计，提取几何特征：
//      * 包围盒 (bounding box)  min_x / max_x / min_y / max_y
//      * 边缘像素总数 feat_edge    —— 近似轮廓周长
//      * 扫描线填充面积 feat_area   —— 每行取「最左边缘像素 .. 最右边缘像素」
//                                     之间的横向游程长度并逐行累加
//      * 填充率 feat_ratio_q        —— feat_area / (box_w * box_h) * 256
//
//  分类依据（填充率，即轮廓内部的充盈程度）：
//      矩形轮廓  : 每行的游程都等于整宽  ->  填充率 = 1.00  (~256)
//      圆形轮廓  : 游程为弦长，面积 = pi*D^2/4 -> 填充率 = pi/4 ~ 0.785 (~201)
//      三角形轮廓: 面积 = W*H/2          ->  填充率 = 0.50  (~128)
//  三者之间有明显间隔，用两个阈值即可稳定区分。
//
//  面积/填充率的除法只在每帧结束时做一次，采用顺序式恢复余数除法器，
//  占用资源极小(约 40 个 LUT)，不影响像素级流水线。
//
//  ---------------------------------------------------------------------------
//  视频流协议（与 cmos_top -> vip_rgb2gray_proc -> Sobeledge_8d_proc 一致）：
//      * 非标 Avalon-ST：sop 对应**一帧**的第一个有效像素，eop 对应一帧的最后
//        一个有效像素（不是每行！）
//      * valid 可能因 FIFO 空而间断，因此像素坐标必须用「只在 valid 时自增」的
//        行列计数器推导，不能依赖 href/行同步。
//      * 本模块与 Sobel 输出同处摄像头像素时钟域 (cmos_pclk)，输出端加寄存器，
//        不引入反馈环路，保持全流水线实时处理。
//==============================================================================
`timescale 1ns/1ps

module shape_recognizer #(
    parameter H_ACTIVE = 1280,          // 图像有效宽度
    parameter V_ACTIVE = 720,           // 图像有效高度
    parameter XW       = 11,            // 列坐标位宽 (1280 -> 11)
    parameter YW       = 10,            // 行坐标位宽 (720  -> 10)
    parameter CW       = 24,            // 面积/计数位宽 (1280*720 = 921600 < 2^20)

    parameter MIN_EDGE = 24'd200,       // 边缘像素数下限，低于此判为「未识别」
    parameter RECT_Q   = 16'd230,       // 填充率 >= 230/256 (0.898) -> 矩形
    parameter CIRC_Q   = 16'd168,       // 填充率 >= 168/256 (0.656) -> 圆形
    parameter TRI_Q    = 16'd96,        // 填充率 >=  96/256 (0.375) -> 三角形

    // 感兴趣区域（ROI）：默认取 1280x720 画面正中的 480x360 窗口。
    // 只统计 ROI 内的边缘，可有效排除背景杂波对几何特征计算的干扰。
    parameter ROI_X0   = 400,
    parameter ROI_X1   = 879,
    parameter ROI_Y0   = 180,
    parameter ROI_Y1   = 539
)(
    input  wire             clk,
    input  wire             rst_n,

    // 像素流（来自 Sobeledge_8d_proc 的 source 端）
    input  wire             st_sop,
    input  wire             st_eop,
    input  wire             st_valid,
    input  wire      [7:0]  st_data,        // Sobel 边缘强度 (0~255)

    // 控制
    input  wire      [7:0]  thresh,         // 边缘二值化阈值，运行时可变
    input  wire             roi_en,         // 0 = 全画面统计，1 = 仅统计 ROI

    // 识别结果（每帧更新一次，保持到下一帧）
    output reg       [1:0]  shape,          // 0=未识别 1=圆形 2=矩形 3=三角形
    output reg       [XW-1:0] box_x0,
    output reg       [XW-1:0] box_x1,
    output reg       [YW-1:0] box_y0,
    output reg       [YW-1:0] box_y1,
    output reg       [CW-1:0] feat_edge,    // 边缘像素数
    output reg       [CW-1:0] feat_area,    // 扫描线填充面积
    output reg       [15:0]   feat_ratio_q, // 填充率 x256 (0 ~ 256)
    output reg                result_valid  // 结果更新完成的单周期脉冲
);

    //--------------------------------------------------------------------------
    // 1. 像素坐标：x 每行绕回，y 行末自增；仅在 valid 时推进，sop 复位
    //--------------------------------------------------------------------------
    reg  [XW-1:0] x_r;
    reg  [YW-1:0] y_r;

    wire [XW-1:0] x_cur = st_sop ? {XW{1'b0}} : x_r;
    wire [YW-1:0] y_cur = st_sop ? {YW{1'b0}} : y_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r <= {XW{1'b0}};
            y_r <= {YW{1'b0}};
        end else if (st_valid) begin
            if (st_sop) begin
                x_r <= (H_ACTIVE <= 1) ? {XW{1'b0}} : {{(XW-1){1'b0}}, 1'b1};
                y_r <= {YW{1'b0}};
            end else if (x_r == H_ACTIVE - 1) begin
                x_r <= {XW{1'b0}};
                y_r <= (y_r == V_ACTIVE - 1) ? {YW{1'b0}} : (y_r + 1'b1);
            end else begin
                x_r <= x_r + 1'b1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 2. ROI 与边缘像素判定
    //--------------------------------------------------------------------------
    wire in_roi = (!roi_en) ||
                  ((x_cur >= ROI_X0) && (x_cur <= ROI_X1) &&
                   (y_cur >= ROI_Y0) && (y_cur <= ROI_Y1));

    wire is_edge = st_valid && in_roi && (st_data >= thresh);

    //--------------------------------------------------------------------------
    // 3. 逐帧累加器声明
    //--------------------------------------------------------------------------
    reg              row_has;
    reg  [XW-1:0]    row_first, row_last;
    reg              acc_any;
    reg  [XW-1:0]    acc_minx, acc_maxx;
    reg  [YW-1:0]    acc_miny, acc_maxy;
    reg  [CW-1:0]    acc_edge, acc_fill;

    //--------------------------------------------------------------------------
    // 4. 当前行的游程长度（组合逻辑，已含当前像素）
    //--------------------------------------------------------------------------
    wire          row_any = is_edge || row_has;                     // 本行是否出现边缘
    wire [XW-1:0] row_lft = row_has ? row_first : x_cur;            // 行内最左
    wire [XW-1:0] row_rgt = is_edge ? x_cur     : row_last;         // 行内最右
    wire [CW-1:0] row_run = row_any
                          ? (({{(CW-XW){1'b0}}, row_rgt} - {{(CW-XW){1'b0}}, row_lft}) + 1'b1)
                          : {CW{1'b0}};

    //--------------------------------------------------------------------------
    // 5. 帧边界
    //--------------------------------------------------------------------------
    wire frame_end = st_valid && st_eop;        // 一帧最后一个像素
    wire row_close = st_valid && (x_cur == H_ACTIVE - 1);   // 一行最后一个像素

    reg  fe_d;                                  // frame_end 打一拍：此周期所有累加量已定型
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fe_d <= 1'b0;
        else        fe_d <= frame_end;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_has   <= 1'b0;
            row_first <= {XW{1'b0}};
            row_last  <= {XW{1'b0}};
            acc_any   <= 1'b0;
            acc_edge  <= {CW{1'b0}};
            acc_fill  <= {CW{1'b0}};
            acc_minx  <= {XW{1'b0}};
            acc_maxx  <= {XW{1'b0}};
            acc_miny  <= {YW{1'b0}};
            acc_maxy  <= {YW{1'b0}};
        end else if (fe_d) begin
            // 本帧已统计完毕，清空累加器等待下一帧
            row_has   <= 1'b0;
            row_first <= {XW{1'b0}};
            row_last  <= {XW{1'b0}};
            acc_any   <= 1'b0;
            acc_edge  <= {CW{1'b0}};
            acc_fill  <= {CW{1'b0}};
            acc_minx  <= {XW{1'b0}};
            acc_maxx  <= {XW{1'b0}};
            acc_miny  <= {YW{1'b0}};
            acc_maxy  <= {YW{1'b0}};
        end else if (st_valid) begin
            if (is_edge) begin
                acc_edge <= acc_edge + 1'b1;
                row_has  <= 1'b1;
                if (!row_has) begin
                    row_first <= x_cur;
                    row_last  <= x_cur;
                end else begin
                    row_last  <= x_cur;
                end

                if (!acc_any) begin
                    acc_any  <= 1'b1;
                    acc_minx <= x_cur;
                    acc_maxx <= x_cur;
                    acc_miny <= y_cur;
                    acc_maxy <= y_cur;
                end else begin
                    if (x_cur < acc_minx) acc_minx <= x_cur;
                    if (x_cur > acc_maxx) acc_maxx <= x_cur;
                    if (y_cur > acc_maxy) acc_maxy <= y_cur;
                end
            end

            if (row_close) begin
                // 本行结束：累加游程。row_run 已把当前像素计入。
                acc_fill  <= acc_fill + row_run;
                row_has   <= 1'b0;
                row_first <= {XW{1'b0}};
                row_last  <= {XW{1'b0}};
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5. 帧末：锁存包围盒与计数，启动除法得到填充率
    //--------------------------------------------------------------------------
    wire [XW:0]   bw       = (acc_maxx - acc_minx) + 1'b1;
    wire [YW:0]   bh       = (acc_maxy - acc_miny) + 1'b1;
    wire [31:0]   box_area = bw * bh;
    wire [31:0]   ratio_num = {8'b0, acc_fill} << 8;   // 分子放大 256 倍

    reg  [31:0]   dv_num, dv_den, dv_rem, dv_quo;
    reg  [5:0]    dv_cnt;
    reg  [1:0]    dv_st;
    reg           dv_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dv_st   <= 2'd0;
            dv_num  <= 32'd0;
            dv_den  <= 32'd0;
            dv_rem  <= 32'd0;
            dv_quo  <= 32'd0;
            dv_cnt  <= 6'd0;
            dv_done <= 1'b0;
        end else begin
            dv_done <= 1'b0;
            case (dv_st)
                2'd0: begin
                    if (fe_d) begin
                        dv_num <= ratio_num;
                        dv_den <= box_area;
                        dv_rem <= 32'd0;
                        dv_quo <= 32'd0;
                        dv_cnt <= 6'd32;
                        dv_st  <= (box_area == 32'd0) ? 2'd2 : 2'd1;
                    end
                end
                2'd1: begin
                    // 恢复余数法：每次移入 1 位被除数
                    if ({dv_rem[30:0], dv_num[31]} >= dv_den) begin
                        dv_rem <= {dv_rem[30:0], dv_num[31]} - dv_den;
                        dv_quo <= {dv_quo[30:0], 1'b1};
                    end else begin
                        dv_rem <= {dv_rem[30:0], dv_num[31]};
                        dv_quo <= {dv_quo[30:0], 1'b0};
                    end
                    dv_num <= {dv_num[30:0], 1'b0};
                    dv_cnt <= dv_cnt - 1'b1;
                    if (dv_cnt == 6'd1) dv_st <= 2'd2;
                end
                default: begin          // 2'd2
                    dv_done <= 1'b1;
                    dv_st   <= 2'd0;
                end
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 6. 结果锁存与分类
    //--------------------------------------------------------------------------
    reg any_r;      // acc_any 在帧末被清零，必须另存一份供分类使用

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feat_edge     <= {CW{1'b0}};
            feat_area     <= {CW{1'b0}};
            box_x0        <= {XW{1'b0}};
            box_x1        <= {XW{1'b0}};
            box_y0        <= {YW{1'b0}};
            box_y1        <= {YW{1'b0}};
            any_r         <= 1'b0;
        end else if (fe_d) begin
            feat_edge <= acc_edge;
            feat_area <= acc_fill;
            any_r     <= acc_any;
            if (acc_any) begin
                box_x0 <= acc_minx;
                box_x1 <= acc_maxx;
                box_y0 <= acc_miny;
                box_y1 <= acc_maxy;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shape         <= 2'd0;
            feat_ratio_q  <= 16'd0;
            result_valid  <= 1'b0;
        end else begin
            result_valid <= dv_done;
            if (dv_done) begin
                feat_ratio_q <= dv_quo[15:0];

                if ((!any_r) || (feat_edge < MIN_EDGE) || (dv_den == 32'd0))
                    shape <= 2'd0;                       // 未识别
                else if (dv_quo >= RECT_Q)
                    shape <= 2'd2;                       // 矩形
                else if (dv_quo >= CIRC_Q)
                    shape <= 2'd1;                       // 圆形
                else if (dv_quo >= TRI_Q)
                    shape <= 2'd3;                       // 三角形
                else
                    shape <= 2'd0;                       // 未识别
            end
        end
    end

endmodule
