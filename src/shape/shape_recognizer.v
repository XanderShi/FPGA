//==============================================================================
//  shape_recognizer.v
//  ---------------------------------------------------------------------------
//  多连通目标识别 —— 逐像素连通域标记 + 帧末分类 (赛题四 高阶挑战 3)
//
//  【与单目标版本的区别】
//  旧版对整个 ROI 只维护一套 min_x/max_x/min_y/max_y/edge_count/scanline_fill。
//  同一行出现两个图形时, 最左边缘与最右边缘之间的空白也会被算进填充面积,
//  包围盒和形状分类都会错。本版把 ROI 内的二值边缘图当作真正的连通域图处理:
//
//    1) 行缓存: 深度 ROI_W+1 的移位寄存器保存「上一行」每个 ROI 像素的标签。
//       当前像素从固定抽头取得 (x+1,y-1)、(x,y-1)、(x-1,y-1), 加上寄存器
//       cur_lbl 得到 (x-1,y), 共 4 个邻居 -> 8 邻域连通。
//    2) 标签合并: 4 个邻居标签各自查一次 root_of[] 得到根。根表始终是完全压缩
//       的(任何时刻 root_of[x] 都是根), 所以查表只有一级 MUX, 不需要并查集
//       链式回溯。取最小的根作为本像素标签, 其余根并入它 —— 合并只改根表,
//       不动统计量, 像素节拍内没有双端口读改写统计表的开销。
//    3) 统计量: 每个标签独立维护 边缘像素数 / 包围盒 / 本行最右 x / 本行行号。
//       填充面积按「扫描线跨度」累加: 一个目标在某行第一次出现时加上本游程长度,
//       之后每次只加上「本游程右端 - 本行已有右端」; 逐行望远镜求和后恰好等于
//       sum(该目标本行最右 - 本行最左 + 1)。这与旧版「每行只按自己的最左到最右
//       累加一次」语义完全一致, 但不会把两个目标之间的空白算进来, 也不需要
//       在行末遍历所有标签。
//    4) 帧末: 非根标签的统计量一次性加进它的根(根表已完全压缩, 与顺序无关);
//       然后逐个根用**同一个**顺序除法器算填充率 -> 分类 -> 最多取 MAX_TARGETS 个。
//       全部处理完后再打一拍 result_valid 单周期脉冲, 结果总线整体更新。
//
//  标签数量上限 MAX_LABEL(默认 63) 就是内部候选连通域上限: 标签只增不减、
//  耗尽后新游程直接丢弃(标签 0), 编号不会回绕, 所以不可能把两个目标错误合并。
//  噪声/碎片各自占用自己的标签, 最后被 MIN_EDGE 过滤掉, 不会污染真实目标。
//
//  ---------------------------------------------------------------------------
//  视频流协议（与 cmos_top -> vip_rgb2gray_proc -> Sobeledge_8d_proc 一致）：
//      * 非标 Avalon-ST：sop 对应**一帧**的第一个有效像素，eop 对应一帧的最后
//        一个有效像素（不是每行！）
//      * valid 可能因 FIFO 空而间断，因此像素坐标必须用「只在 valid 时自增」的
//        行列计数器推导，不能依赖 href/行同步；连通域标记、行缓存、统计量全部
//        只在 valid 时推进。
//      * 本模块与 Sobel 输出同处摄像头像素时钟域 (cmos_pclk)，输出端加寄存器，
//        不引入反馈环路，保持全流水线实时处理。
//
//  结果总线 targets 的打包格式 (每个目标 TBW 位, 目标 0 在最低位):
//      [1:0] shape  0=未识别 1=圆形 2=矩形 3=三角形
//      [12:2] x0    [23:13] x1     [33:24] y0    [43:34] y1
//      [59:44] ratio_q (填充率 x256)
//      [79:60] edge_cnt (边缘像素数, 供仿真/调试检查)
//  见 shape_overlay.v 里同名的 TB_O_* 常量。
//==============================================================================
`timescale 1ns/1ps

module shape_recognizer #(
    parameter H_ACTIVE    = 1280,       // 图像有效宽度
    parameter V_ACTIVE    = 720,        // 图像有效高度
    parameter XW          = 11,         // 列坐标位宽 (1280 -> 11)
    parameter YW          = 10,         // 行坐标位宽 (720  -> 10)
    parameter CW          = 20,         // 面积/计数位宽 (1280*720 = 921600 < 2^20)

    parameter MIN_EDGE    = 20'd400,    // 边缘像素数下限，低于此判为「未识别」
    parameter RECT_Q      = 16'd230,    // 填充率 >= 230/256 (0.898) -> 矩形
    parameter CIRC_Q      = 16'd168,    // 填充率 >= 168/256 (0.656) -> 圆形
    parameter TRI_Q       = 16'd96,     // 填充率 >=  96/256 (0.375) -> 三角形

    // 感兴趣区域（ROI）：默认取 1280x720 画面正中的 480x360 窗口。
    // 只统计 ROI 内的边缘，可有效排除背景杂波对几何特征计算的干扰。
    // 行缓存按 ROI 宽度定长，因此分析窗口就是这组参数定义的窗口。
    parameter ROI_X0      = 400,
    parameter ROI_X1      = 879,
    parameter ROI_Y0      = 180,
    parameter ROI_Y1      = 539,

    parameter MAX_TARGETS = 4,          // 一帧最多输出的目标数
    parameter MAX_LABEL   = 63,         // 内部候选连通域上限 (<= 63, 对应 LBW=6)
    parameter LBW         = 6,          // 标签位宽, MAX_LABEL 必须 <= 2^LBW-1
    parameter TCNT_W      = 4,          // target_count 位宽, 需能表示 0..MAX_TARGETS
    parameter TBW         = 80          // 单目标结果位宽 = 2+XW+XW+YW+YW+16+CW
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

    // 识别结果（每帧更新一次，保持到下一帧）
    output reg  [TCNT_W-1:0]         target_count,
    output wire [MAX_TARGETS*TBW-1:0] targets,
    output reg                       result_valid
);

    localparam ROI_W = ROI_X1 - ROI_X0 + 1;     // ROI 列数 (默认 480)

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
    // 2. ROI 判定 + 上一行标签行缓存
    //    移位寄存器第 0 位是刚移入的像素, 所以处理像素 x 时(已经移入 x-1 个)
    //    plane[ROI_W-2] = 上一行 x+1, plane[ROI_W-1] = 上一行 x,
    //    plane[ROI_W]   = 上一行 x-1 (推导见头注释)。
    //    行首/行尾/帧首的越界邻居读出来强制清 0, 所以行缓存不需要复位。
    //--------------------------------------------------------------------------
    reg  [LBW-1:0] plane [0:ROI_W];

    wire in_roi_x  = (x_cur >= ROI_X0) && (x_cur <= ROI_X1);
    wire in_roi    = in_roi_x && (y_cur >= ROI_Y0) && (y_cur <= ROI_Y1);
    wire is_edge   = st_valid && in_roi && (st_data >= thresh);
    wire first_row = (y_cur == ROI_Y0);         // 帧内第一行 ROI: 上一行无效

    wire [LBW-1:0] prv_m1 = (first_row || (x_cur == ROI_X0)) ? {LBW{1'b0}} : plane[ROI_W];
    wire [LBW-1:0] prv_c  =  first_row                       ? {LBW{1'b0}} : plane[ROI_W-1];
    wire [LBW-1:0] prv_p1 = (first_row || (x_cur == ROI_X1)) ? {LBW{1'b0}} : plane[ROI_W-2];

    // 当前像素标签(根) / 本行左邻居标签(0 = 非边缘)
    wire [LBW-1:0] pix_lbl;
    reg  [LBW-1:0] cur_lbl;

    wire [LBW-1:0] plane_in = pix_lbl;

    integer pk;
    always @(posedge clk) begin
        if (st_valid && in_roi_x) begin
            for (pk = ROI_W; pk > 0; pk = pk - 1)
                plane[pk] <= plane[pk-1];
            plane[0] <= plane_in;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      cur_lbl <= {LBW{1'b0}};
        else if (st_sop) cur_lbl <= {LBW{1'b0}};
        else if (st_valid) cur_lbl <= is_edge ? pix_lbl : {LBW{1'b0}};
    end

    //--------------------------------------------------------------------------
    // 3. 连通域标记: 4 个邻居 -> 根表查表 -> 取最小根 -> 其余根并入
    //--------------------------------------------------------------------------
    // 根表: 任何时刻 root_of[x] 都是 x 所在连通域的根 (完全压缩)
    reg  [LBW-1:0] root_of [0:MAX_LABEL];

    wire [LBW-1:0] rt_l  = root_of[cur_lbl];    // (x-1,y)
    wire [LBW-1:0] rt_m1 = root_of[prv_m1];     // (x-1,y-1)
    wire [LBW-1:0] rt_c  = root_of[prv_c];      // (x,  y-1)
    wire [LBW-1:0] rt_p1 = root_of[prv_p1];     // (x+1,y-1)

    // 4 个候选中取最小的非零值; 全 0 表示没有邻居(新连通域)
    function [LBW-1:0] min4_nz;
        input [LBW-1:0] a, b, c, d;
        reg   [LBW-1:0] m;
        begin
            m = {LBW{1'b0}};
            if (a != {LBW{1'b0}}) m = a;
            if ((b != {LBW{1'b0}}) && ((m == {LBW{1'b0}}) || (b < m))) m = b;
            if ((c != {LBW{1'b0}}) && ((m == {LBW{1'b0}}) || (c < m))) m = c;
            if ((d != {LBW{1'b0}}) && ((m == {LBW{1'b0}}) || (d < m))) m = d;
            min4_nz = m;
        end
    endfunction

    wire [LBW-1:0] grp = min4_nz(rt_l, rt_m1, rt_c, rt_p1);

    // 新标签分配: 只增不减, 超过 MAX_LABEL 后不再分配(编号不回绕)
    reg  [LBW:0] next_lbl;
    wire         lbl_free = (next_lbl <= MAX_LABEL);
    wire         alloc_new = is_edge && (grp == {LBW{1'b0}}) && lbl_free;

    assign pix_lbl = !is_edge                        ? {LBW{1'b0}} :
                     (grp != {LBW{1'b0}})            ? grp :
                     alloc_new                       ? next_lbl[LBW-1:0] :
                                                       {LBW{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          next_lbl <= {{LBW{1'b0}}, 1'b1};
        else if (st_sop)     next_lbl <= {{LBW{1'b0}}, 1'b1};
        else if (alloc_new)  next_lbl <= next_lbl + 1'b1;
    end

    // 合并: 把所有「根等于 4 个邻居根之一」的项改成本像素的根 grp
    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ri = 0; ri <= MAX_LABEL; ri = ri + 1) root_of[ri] <= ri;
        end else if (st_sop) begin
            for (ri = 0; ri <= MAX_LABEL; ri = ri + 1) root_of[ri] <= ri;
        end else if (is_edge && (grp != {LBW{1'b0}})) begin
            for (ri = 1; ri <= MAX_LABEL; ri = ri + 1)
                if ((root_of[ri] == rt_l) || (root_of[ri] == rt_m1) ||
                    (root_of[ri] == rt_c) || (root_of[ri] == rt_p1))
                    root_of[ri] <= grp;
        end
    end

    //--------------------------------------------------------------------------
    // 4. 游程结束事件 (一个游程 = 一行内连续的一段边缘像素)
    //    统计量按游程更新, 每行每目标只累加一次自己的跨度, 因此目标之间的
    //    空白不会被计算; 行尾最后一列/帧尾也要强制收口, 避免游程跨行.
    //--------------------------------------------------------------------------
    reg  [LBW-1:0] run_lbl;
    reg  [XW-1:0]  run_x0, run_x1;
    reg  [YW-1:0]  run_y;
    reg            run_act;

    wire at_last_col = (x_cur == ROI_X1);
    wire frame_end   = st_valid && st_eop;

    wire run_close_now = run_act && (!is_edge || at_last_col || frame_end);
    wire run_single    = !run_act && is_edge && (at_last_col || frame_end);
    wire u_valid       = st_valid && (run_close_now || run_single);

    wire [XW-1:0]  u_x0  = run_act ? run_x0 : x_cur;
    wire [XW-1:0]  u_x1  = is_edge ? x_cur  : run_x1;   // 收口时本像素就是右端点
    wire [YW-1:0]  u_y   = run_act ? run_y  : y_cur;
    wire [LBW-1:0] u_lsrc = run_act ? run_lbl : pix_lbl;
    wire [LBW-1:0] u_lbl  = root_of[u_lsrc];            // 用当前根, 合并后仍然正确

    // 打一拍: 把「游程结束」这条事件锁存下来, 下一拍再读改写统计表。
    // 这样「像素 -> 邻居 -> 根表 -> 最小根」的组合链只到 u_lbl 寄存器为止,
    // 统计表的读地址来自寄存器, 100MHz 像素时钟下的关键路径被切开。
    // 相邻两次游程结束至少间隔 1 拍(偶数拍也安全: 上一拍的数据已被消费)。
    reg           pu_valid;
    reg  [LBW-1:0] pu_lbl;
    reg  [XW-1:0]  pu_x0, pu_x1;
    reg  [YW-1:0]  pu_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pu_valid <= 1'b0;
            pu_lbl   <= {LBW{1'b0}};
            pu_x0    <= {XW{1'b0}};
            pu_x1    <= {XW{1'b0}};
            pu_y     <= {YW{1'b0}};
        end else if (st_sop) begin
            pu_valid <= 1'b0;
            pu_lbl   <= {LBW{1'b0}};
            pu_x0    <= {XW{1'b0}};
            pu_x1    <= {XW{1'b0}};
            pu_y     <= {YW{1'b0}};
        end else begin
            pu_valid <= u_valid && (u_lbl != {LBW{1'b0}});
            if (u_valid) begin
                pu_lbl <= u_lbl;
                pu_x0  <= u_x0;
                pu_x1  <= u_x1;
                pu_y   <= u_y;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_act <= 1'b0;
            run_lbl <= {LBW{1'b0}};
            run_x0  <= {XW{1'b0}};
            run_x1  <= {XW{1'b0}};
            run_y   <= {YW{1'b0}};
        end else if (st_sop) begin
            run_act <= 1'b0;
            run_lbl <= {LBW{1'b0}};
            run_x0  <= {XW{1'b0}};
            run_x1  <= {XW{1'b0}};
            run_y   <= {YW{1'b0}};
        end else if (st_valid) begin
            if (is_edge) begin
                if (!run_act) begin
                    run_act <= 1'b1;
                    run_lbl <= pix_lbl;
                    run_x0  <= x_cur;
                    run_y   <= y_cur;
                end
                run_x1 <= x_cur;
                if (at_last_col || frame_end) run_act <= 1'b0;
            end else if (run_act) begin
                run_act <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5. 每个标签的统计量
    //    索引 0 保留不用 (标签 0 = 无标签)
    //--------------------------------------------------------------------------
    reg [CW-1:0] st_edge   [0:MAX_LABEL];   // 边缘像素数
    reg [CW-1:0] st_fill   [0:MAX_LABEL];   // 扫描线填充面积
    reg [XW-1:0] st_minx   [0:MAX_LABEL];
    reg [XW-1:0] st_maxx   [0:MAX_LABEL];
    reg [YW-1:0] st_miny   [0:MAX_LABEL];
    reg [YW-1:0] st_maxy   [0:MAX_LABEL];
    reg [YW-1:0] st_rowy   [0:MAX_LABEL];   // 上次出现所在行
    reg [XW-1:0] st_rowmax [0:MAX_LABEL];   // 该行已见的最右 x

    // 读口: 帧内读游程标签, 帧末读归并/扫描下标
    //   ST_DRAIN: 帧尾多留一拍, 让最后一条"游程结束"的统计更新落地
    reg  [2:0]    fsm;
    localparam ST_LIVE = 3'd0, ST_DRAIN = 3'd1, ST_FOLD = 3'd2,
                 ST_SCAN = 3'd3, ST_EMIT  = 3'd4;

    reg  [LBW:0]  idx;
    reg           fold_ph;
    reg           scan_ph;
    reg  [LBW-1:0] fold_root;

    wire [LBW-1:0] idx_l   = idx[LBW-1:0];
    wire           live_we = ((fsm == ST_LIVE) || (fsm == ST_DRAIN)) && pu_valid;
    wire [LBW-1:0] rd_addr = live_we ? pu_lbl :
                             ((fsm == ST_FOLD) && fold_ph) ? fold_root : idx_l;

    reg  [CW-1:0] r_edge, r_fill;
    reg  [XW-1:0] r_minx, r_maxx, r_rowmax;
    reg  [YW-1:0] r_miny, r_maxy, r_rowy;
    always @(*) begin
        r_edge   = st_edge  [rd_addr];
        r_fill   = st_fill  [rd_addr];
        r_minx   = st_minx  [rd_addr];
        r_maxx   = st_maxx  [rd_addr];
        r_miny   = st_miny  [rd_addr];
        r_maxy   = st_maxy  [rd_addr];
        r_rowy   = st_rowy  [rd_addr];
        r_rowmax = st_rowmax[rd_addr];
    end

    // 单端口写口: 帧内写游程更新, 帧末写归并结果
    reg           st_we;
    reg  [LBW-1:0] st_wa;
    reg  [CW-1:0] st_wedge, st_wfill;
    reg  [XW-1:0] st_wminx, st_wmaxx, st_wrowmax;
    reg  [YW-1:0] st_wminy, st_wmaxy, st_wrowy;

    wire [XW:0] u_span = {1'b0, pu_x1} - {1'b0, pu_x0} + 1'b1;    // 游程长度
    wire [XW:0] u_gap  = {1'b0, pu_x1} - {1'b0, r_rowmax};        // 本行跨度增量
    // 同一行内同一标签的游程 x1 一定递增; 若因标签合并拿到更大的 rowmax,
    // 就退化成按本游程长度累加, 只用最坏情况轻微高估, 不允许减法下溢。
    wire        u_seg_new = (r_rowy != pu_y) || (pu_x1 <= r_rowmax);

    // 归并暂存
    reg  [CW-1:0] f_edge, f_fill;
    reg  [XW-1:0] f_minx, f_maxx;
    reg  [YW-1:0] f_miny, f_maxy;

    always @(*) begin
        st_we      = 1'b0;
        st_wa      = {LBW{1'b0}};
        st_wedge   = {CW{1'b0}};
        st_wfill   = {CW{1'b0}};
        st_wminx   = {XW{1'b0}};
        st_wmaxx   = {XW{1'b0}};
        st_wminy   = {YW{1'b0}};
        st_wmaxy   = {YW{1'b0}};
        st_wrowy   = {YW{1'b0}};
        st_wrowmax = {XW{1'b0}};

        if (live_we) begin
            st_we      = 1'b1;
            st_wa      = pu_lbl;
            st_wedge   = r_edge + u_span;
            st_wfill   = r_fill + (u_seg_new ? u_span : u_gap);
            st_wrowy   = pu_y;
            st_wrowmax = pu_x1;
            if (r_edge == {CW{1'b0}}) begin
                st_wminx = pu_x0;
                st_wmaxx = pu_x1;
                st_wminy = pu_y;
                st_wmaxy = pu_y;
            end else begin
                st_wminx = (pu_x0 < r_minx) ? pu_x0 : r_minx;
                st_wmaxx = (pu_x1 > r_maxx) ? pu_x1 : r_maxx;
                st_wminy = (pu_y  < r_miny) ? pu_y  : r_miny;
                st_wmaxy = (pu_y  > r_maxy) ? pu_y  : r_maxy;
            end
        end else if ((fsm == ST_FOLD) && fold_ph) begin
            st_we      = 1'b1;
            st_wa      = fold_root;
            st_wedge   = r_edge + f_edge;
            st_wfill   = r_fill + f_fill;
            st_wminx   = (f_minx < r_minx) ? f_minx : r_minx;
            st_wmaxx   = (f_maxx > r_maxx) ? f_maxx : r_maxx;
            st_wminy   = (f_miny < r_miny) ? f_miny : r_miny;
            st_wmaxy   = (f_maxy > r_maxy) ? f_maxy : r_maxy;
            st_wrowy   = r_rowy;
            st_wrowmax = r_rowmax;
        end
    end

    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (si = 0; si <= MAX_LABEL; si = si + 1) begin
                st_edge[si]   <= {CW{1'b0}};
                st_fill[si]   <= {CW{1'b0}};
                st_minx[si]   <= {XW{1'b0}};
                st_maxx[si]   <= {XW{1'b0}};
                st_miny[si]   <= {YW{1'b0}};
                st_maxy[si]   <= {YW{1'b0}};
                st_rowy[si]   <= {YW{1'b0}};
                st_rowmax[si] <= {XW{1'b0}};
            end
        end else if (st_sop) begin
            // 新的一帧: 所有标签的统计量清零(帧末后处理早已结束)
            for (si = 0; si <= MAX_LABEL; si = si + 1) begin
                st_edge[si]   <= {CW{1'b0}};
                st_fill[si]   <= {CW{1'b0}};
                st_minx[si]   <= {XW{1'b0}};
                st_maxx[si]   <= {XW{1'b0}};
                st_miny[si]   <= {YW{1'b0}};
                st_maxy[si]   <= {YW{1'b0}};
                st_rowy[si]   <= {YW{1'b0}};
                st_rowmax[si] <= {XW{1'b0}};
            end
        end else if (st_we) begin
            st_edge  [st_wa] <= st_wedge;
            st_fill  [st_wa] <= st_wfill;
            st_minx  [st_wa] <= st_wminx;
            st_maxx  [st_wa] <= st_wmaxx;
            st_miny  [st_wa] <= st_wminy;
            st_maxy  [st_wa] <= st_wmaxy;
            st_rowy  [st_wa] <= st_wrowy;
            st_rowmax[st_wa] <= st_wrowmax;
        end
    end

    //--------------------------------------------------------------------------
    // 6. 共享顺序除法器 (帧末逐个目标算填充率, 全模块只有一个)
    //--------------------------------------------------------------------------
    reg  [31:0] dv_num, dv_den, dv_rem, dv_quo;
    reg  [5:0]  dv_cnt;
    reg  [1:0]  dv_st;
    reg         dv_done;

    wire [XW:0]  bw   = (r_maxx - r_minx) + 1'b1;
    wire [YW:0]  bh   = (r_maxy - r_miny) + 1'b1;
    wire [23:0]  box_area = bw * bh;

    wire cand_ok = (fsm == ST_SCAN) && (idx <= MAX_LABEL) && !scan_ph &&
                   (root_of[idx_l] == idx_l) && (r_edge >= MIN_EDGE) &&
                   (bw != 0) && (bh != 0);
    wire dv_start = cand_ok;

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
                    if (dv_start) begin
                        dv_num <= {4'b0, r_fill} << 8;      // 分子放大 256 倍
                        dv_den <= {8'b0, box_area};
                        dv_rem <= 32'd0;
                        dv_quo <= 32'd0;
                        dv_cnt <= 6'd32;
                        dv_st  <= (box_area == 24'd0) ? 2'd2 : 2'd1;
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
    // 7. 输出目标表 (扁平打包, MAX_TARGETS 个槽)
    //--------------------------------------------------------------------------
    reg [MAX_TARGETS*2-1:0]  t_shape;
    reg [MAX_TARGETS*XW-1:0] t_x0, t_x1;
    reg [MAX_TARGETS*YW-1:0] t_y0, t_y1;
    reg [MAX_TARGETS*16-1:0] t_ratio;
    reg [MAX_TARGETS*CW-1:0] t_edge;
    reg [TCNT_W-1:0]         out_cnt;

    genvar gi;
    generate
        for (gi = 0; gi < MAX_TARGETS; gi = gi + 1) begin : g_pack
            assign targets[gi*TBW +: TBW] = {
                t_edge [gi*CW +: CW],
                t_ratio[gi*16 +: 16],
                t_y1   [gi*YW +: YW],
                t_y0   [gi*YW +: YW],
                t_x1   [gi*XW +: XW],
                t_x0   [gi*XW +: XW],
                t_shape[gi*2  +: 2 ]
            };
        end
    endgenerate

    // 填充率 -> 类别 (dv_quo 在 dv_done 时有效)
    wire [1:0] shape_c = (dv_quo >= RECT_Q) ? 2'd2 :
                         (dv_quo >= CIRC_Q) ? 2'd1 :
                         (dv_quo >= TRI_Q ) ? 2'd3 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm          <= ST_LIVE;
            idx          <= {(LBW+1){1'b0}};
            fold_ph      <= 1'b0;
            scan_ph      <= 1'b0;
            fold_root    <= {LBW{1'b0}};
            f_edge       <= {CW{1'b0}};
            f_fill       <= {CW{1'b0}};
            f_minx       <= {XW{1'b0}};
            f_maxx       <= {XW{1'b0}};
            f_miny       <= {YW{1'b0}};
            f_maxy       <= {YW{1'b0}};
            out_cnt      <= {TCNT_W{1'b0}};
            t_shape      <= {MAX_TARGETS*2{1'b0}};
            t_x0         <= {MAX_TARGETS*XW{1'b0}};
            t_x1         <= {MAX_TARGETS*XW{1'b0}};
            t_y0         <= {MAX_TARGETS*YW{1'b0}};
            t_y1         <= {MAX_TARGETS*YW{1'b0}};
            t_ratio      <= {MAX_TARGETS*16{1'b0}};
            t_edge       <= {MAX_TARGETS*CW{1'b0}};
            target_count <= {TCNT_W{1'b0}};
            result_valid <= 1'b0;
        end else begin
            result_valid <= 1'b0;

            case (fsm)
                //------------------------------------------ 帧内: 标记 + 统计
                ST_LIVE: begin
                    if (frame_end) begin
                        fsm     <= ST_DRAIN;
                        idx     <= MAX_LABEL;
                        fold_ph <= 1'b0;
                        out_cnt <= {TCNT_W{1'b0}};
                        t_shape <= {MAX_TARGETS*2{1'b0}};
                        t_x0    <= {MAX_TARGETS*XW{1'b0}};
                        t_x1    <= {MAX_TARGETS*XW{1'b0}};
                        t_y0    <= {MAX_TARGETS*YW{1'b0}};
                        t_y1    <= {MAX_TARGETS*YW{1'b0}};
                        t_ratio <= {MAX_TARGETS*16{1'b0}};
                        t_edge  <= {MAX_TARGETS*CW{1'b0}};
                    end
                end

                //------------------------------------------ 帧尾多留一拍
                ST_DRAIN: begin
                    fsm     <= ST_FOLD;
                    idx     <= MAX_LABEL;
                    fold_ph <= 1'b0;
                end

                //------------------------------------------ 帧末: 非根标签并入根
                // 根表完全压缩, 每次直接把 stat[i] 加到 stat[root_of[i]] 即可,
                // 与处理顺序无关, 所以一个下标一趟就够。
                ST_FOLD: begin
                    if (!fold_ph) begin
                        if (idx == {(LBW+1){1'b0}}) begin
                            fsm     <= ST_SCAN;
                            idx     <= {{(LBW){1'b0}}, 1'b1};
                            scan_ph <= 1'b0;
                        end else if ((root_of[idx_l] == idx_l) || (r_edge == {CW{1'b0}})) begin
                            // 已经是根, 或者只是被合并掉的空标签(没有统计量): 跳过
                            idx <= idx - 1'b1;
                        end else begin
                            fold_root <= root_of[idx_l];
                            f_edge    <= r_edge;
                            f_fill    <= r_fill;
                            f_minx    <= r_minx;
                            f_maxx    <= r_maxx;
                            f_miny    <= r_miny;
                            f_maxy    <= r_maxy;
                            fold_ph   <= 1'b1;
                        end
                    end else begin
                        fold_ph <= 1'b0;
                        idx     <= idx - 1'b1;
                    end
                end

                //------------------------------------------ 帧末: 逐个候选目标分类
                ST_SCAN: begin
                    if (!scan_ph) begin
                        if (idx > MAX_LABEL) begin
                            fsm <= ST_EMIT;
                        end else if (cand_ok) begin
                            scan_ph <= 1'b1;                // 已启动除法器
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end else if (dv_done) begin
                        if ((shape_c != 2'd0) && (out_cnt < MAX_TARGETS)) begin
                            t_shape[out_cnt*2  +: 2 ] <= shape_c;
                            t_x0   [out_cnt*XW +: XW] <= r_minx;
                            t_x1   [out_cnt*XW +: XW] <= r_maxx;
                            t_y0   [out_cnt*YW +: YW] <= r_miny;
                            t_y1   [out_cnt*YW +: YW] <= r_maxy;
                            t_ratio[out_cnt*16 +: 16] <= dv_quo[15:0];
                            t_edge [out_cnt*CW +: CW] <= r_edge;
                            out_cnt <= out_cnt + 1'b1;
                        end
                        idx     <= idx + 1'b1;
                        scan_ph <= 1'b0;
                    end
                end

                //------------------------------------------ 一次性更新结果
                default: begin  // ST_EMIT
                    target_count <= out_cnt;
                    result_valid <= 1'b1;
                    fsm          <= ST_LIVE;
                end
            endcase
        end
    end

endmodule
