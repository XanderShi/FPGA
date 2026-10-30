//==============================================================================
//  tb_shape_recognizer.v
//  ---------------------------------------------------------------------------
//  多目标识别 shape_recognizer 的自检测试平台。
//
//  直接在仿真里合成「边缘图」像素流（圆形/矩形/三角形轮廓, 可同时出现多个,
//  另加空白帧/孤立噪声/valid 断续），按真实协议送入 DUT：
//      * sop 只在**一帧**的第一个像素有效，eop 只在最后一帧的最后一个像素有效
//      * valid 会被随机拉低来模拟采集 FIFO 空导致的停顿（验证坐标计数正确性）
//  然后等待 result_valid，比对目标数量、每个目标的类别和包围盒
//  （包围盒允许 ±2 像素的线宽误差），并同时检查经 shape_result_cdc 搬到
//  另一个时钟域(7ns)的整条结果总线，验证多帧切换时不会残留旧目标。
//
//  为便于仿真，分辨率缩小到 200x150，ROI 覆盖全画面；分类阈值与原设计一致
//  （填充率与分辨率无关）。四个图形分别放在四个互不重叠的格子里:
//      格子0 (45,40)   格子1 (150,40)       <- 同一水平带, 专门验证不会把
//      格子2 (50,110)  格子3 (150,110)         两个图形之间的空白算进填充面积
//
//  ModelSim :  vlog shape_recognizer.v shape_result_cdc.v tb_shape_recognizer.v
//              vsim -c tb_shape_recognizer
//==============================================================================
`timescale 1ns/1ps

module tb_shape_recognizer;

    // 画面比 ROI 大, 且 ROI 不贴边: 与上板一致地验证 ROI 窗口/行缓存抽头/
    // 行首行尾屏蔽 (ROI 宽度 480 -> 行缓存深度 481, 与生产配置相同)
    localparam H    = 520;
    localparam V    = 150;
    localparam RX0  = 20;
    localparam RX1  = 499;
    localparam RY0  = 10;
    localparam RY1  = 140;
    localparam MAXT = 4;
    localparam TBW  = 80;

    // 期望的分类编码
    localparam S_NONE = 2'd0;
    localparam S_CIRC = 2'd1;
    localparam S_RECT = 2'd2;
    localparam S_TRI  = 2'd3;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    always #5 clk = ~clk;               // 100 MHz (像素域)
    reg  clk_b = 1'b0;
    always #3.5 clk_b = ~clk_b;         // 142 MHz (显示域, 故意用不同频率)

    reg         sop, eop, valid;
    reg  [7:0]  data;
    reg  [7:0]  thresh = 8'd24;

    wire [3:0]  tcount;
    wire [MAXT*TBW-1:0] tbus;
    wire        rvalid;

    integer errors = 0;

    shape_recognizer #(
        .H_ACTIVE    (H),
        .V_ACTIVE    (V),
        .XW          (11),
        .YW          (10),
        .CW          (20),
        .MIN_EDGE    (20'd80),
        .RECT_Q      (16'd230),
        .CIRC_Q      (16'd168),
        .TRI_Q       (16'd96),
        .ROI_X0      (RX0),
        .ROI_X1      (RX1),
        .ROI_Y0      (RY0),
        .ROI_Y1      (RY1),
        .MAX_TARGETS (MAXT),
        .MAX_LABEL   (63),
        .LBW         (6),
        .TCNT_W      (4),
        .TBW         (TBW)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .st_sop       (sop),
        .st_eop       (eop),
        .st_valid     (valid),
        .st_data      (data),
        .thresh       (thresh),
        .target_count (tcount),
        .targets      (tbus),
        .result_valid (rvalid)
    );

    // ---- 结果总线跨到另一个时钟域, 一起验证 CDC 搬运 ----
    wire [3:0]          cdc_cnt;
    wire [MAXT*TBW-1:0] cdc_bus;
    wire                cdc_vld;

    shape_result_cdc #(
        .MAX_TARGETS (MAXT),
        .TBW         (TBW),
        .TCNT_W      (4)
    ) u_cdc (
        .clk_a     (clk),
        .rst_a_n   (rst_n),
        .load      (rvalid),
        .count_a   (tcount),
        .targets_a (tbus),
        .clk_b     (clk_b),
        .rst_b_n   (rst_n),
        .count_b   (cdc_cnt),
        .targets_b (cdc_bus),
        .valid_b   (cdc_vld)
    );

    //--------------------------------------------------------------------------
    // 结果捕获 (两域各一份, 粘滞到下一次取走)
    //--------------------------------------------------------------------------
    reg [3:0]           cap_cnt;
    reg [MAXT*TBW-1:0]  cap_bus;
    reg                 cap_flag;
    always @(posedge clk) if (rvalid) begin
        cap_cnt  <= tcount;
        cap_bus  <= tbus;
        cap_flag <= 1'b1;
    end

    reg [3:0]           cdc_cap_cnt;
    reg [MAXT*TBW-1:0]  cdc_cap_bus;
    reg                 cdc_cap_flag;
    always @(posedge clk_b) if (cdc_vld) begin
        cdc_cap_cnt  <= cdc_cnt;
        cdc_cap_bus  <= cdc_bus;
        cdc_cap_flag <= 1'b1;
    end

    //--------------------------------------------------------------------------
    // 场景描述: 最多 4 个图形 + 若干孤立小噪声块(4x4, 远小于 MIN_EDGE)
    //--------------------------------------------------------------------------
    integer nsh;
    integer sh_kind [0:3];
    integer sh_cx   [0:3];
    integer sh_cy   [0:3];

    integer nnoise;
    integer nz_x [0:7];
    integer nz_y [0:7];

    // 单个图形的边缘像素判定
    //   kind 1 = 圆环 (r 19..22)        : 包围盒 ±22
    //   kind 2 = 矩形轮廓 50x36 线宽 2  : 包围盒 ±25 / ±18
    //   kind 3 = 三角形轮廓 底 60 高 40 : 包围盒 ±31 / ±20
    function is_shape_pix;
        input integer kind;
        input integer cx, cy;
        input integer x, y;
        integer dx, dy, adx, ady, d2, top, bot, hw;
        begin
            is_shape_pix = 1'b0;
            dx  = x - cx;
            dy  = y - cy;
            adx = (dx < 0) ? -dx : dx;
            ady = (dy < 0) ? -dy : dy;
            case (kind)
                1: begin
                    d2 = dx*dx + dy*dy;
                    if ((d2 >= 19*19) && (d2 <= 22*22)) is_shape_pix = 1'b1;
                end
                2: begin
                    if ((adx <= 25) && (ady <= 18) &&
                        (((25 - adx) < 2) || ((18 - ady) < 2))) is_shape_pix = 1'b1;
                end
                3: begin
                    top = cy - 20;
                    bot = cy + 20;
                    if ((y >= top) && (y <= bot)) begin
                        hw = (30 * (y - top)) / (bot - top);
                        if ((adx >= (hw - 1)) && (adx <= (hw + 1))) is_shape_pix = 1'b1;
                        if ((y == bot) && (adx <= 31)) is_shape_pix = 1'b1;
                    end
                end
                default: is_shape_pix = 1'b0;
            endcase
        end
    endfunction

    // 整幅边缘图 = 各图形轮廓 OR 各噪声块
    function is_edge_pix;
        input integer x, y;
        integer s, n;
        begin
            is_edge_pix = 1'b0;
            for (s = 0; s < nsh; s = s + 1)
                if (is_shape_pix(sh_kind[s], sh_cx[s], sh_cy[s], x, y)) is_edge_pix = 1'b1;
            for (n = 0; n < nnoise; n = n + 1)
                if ((x >= nz_x[n]) && (x < nz_x[n] + 4) &&
                    (y >= nz_y[n]) && (y < nz_y[n] + 4)) is_edge_pix = 1'b1;
        end
    endfunction

    // 格子中心
    task place;
        input integer s;
        input integer kind;
        begin
            sh_kind[s] = kind;
            case (s)
                0: begin sh_cx[s] =  60; sh_cy[s] =  40; end
                1: begin sh_cx[s] = 160; sh_cy[s] =  40; end
                2: begin sh_cx[s] =  60; sh_cy[s] = 110; end
                default: begin sh_cx[s] = 160; sh_cy[s] = 110; end
            endcase
        end
    endtask

    //--------------------------------------------------------------------------
    // 送一个像素；gap=1 时先插入一个 valid=0 的空拍模拟 FIFO 停顿
    //--------------------------------------------------------------------------
    task send_pixel;
        input        sop_v;
        input        eop_v;
        input [7:0]  d;
        input        gap;
        begin
            @(negedge clk);
            data  = d;
            sop   = sop_v;
            eop   = eop_v;
            valid = 1'b1;
            @(negedge clk);
            valid = 1'b0;
            sop   = 1'b0;
            eop   = 1'b0;
            if (gap) @(negedge clk);        // 停顿拍：valid 保持 0
        end
    endtask

    //--------------------------------------------------------------------------
    // 送一整帧
    //--------------------------------------------------------------------------
    task send_frame;
        input gap_en;
        integer x, y;
        begin
            for (y = 0; y < V; y = y + 1)
                for (x = 0; x < H; x = x + 1)
                    send_pixel((x == 0) && (y == 0),
                               (x == H - 1) && (y == V - 1),
                               is_edge_pix(x, y) ? 8'hFF : 8'h00,
                               gap_en && (((x + y) % 11) == 0));
        end
    endtask

    //--------------------------------------------------------------------------
    // 取结果（clk 域 + CDC 域）
    //--------------------------------------------------------------------------
    task get_result;
        begin
            @(negedge clk);
            cap_flag = 1'b0;
            while (cap_flag !== 1'b1) @(negedge clk);
            @(negedge clk_b);
            cdc_cap_flag = 1'b0;
            while (cdc_cap_flag !== 1'b1) @(negedge clk_b);
        end
    endtask

    // 结果总线字段
    function [1:0]  f_shape;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_shape = bus[i*TBW + 0 +: 2]; end
    endfunction
    function [10:0] f_x0;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_x0 = bus[i*TBW + 2 +: 11]; end
    endfunction
    function [10:0] f_x1;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_x1 = bus[i*TBW + 13 +: 11]; end
    endfunction
    function [9:0]  f_y0;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_y0 = bus[i*TBW + 24 +: 10]; end
    endfunction
    function [9:0]  f_y1;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_y1 = bus[i*TBW + 34 +: 10]; end
    endfunction
    function [15:0] f_ratio;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_ratio = bus[i*TBW + 44 +: 16]; end
    endfunction
    function [19:0] f_edge;
        input [MAXT*TBW-1:0] bus;
        input integer i;
        begin f_edge = bus[i*TBW + 60 +: 20]; end
    endfunction

    //--------------------------------------------------------------------------
    // 比对一帧：目标数 + 每个图形的类别/包围盒 (+ 两域一致)
    //--------------------------------------------------------------------------
    integer used [0:3];
    integer m, s, b, bd, d, ex0, ex1, ey0, ey1, ecx, ecy, dcx, dcy, bix;
    reg [8*28-1:0] tname;

    task check_frame;
        input integer exp_n;
        begin
            get_result();

            if (cap_cnt !== exp_n[3:0]) begin
                $display("FAIL  %0s : target_count=%0d expect %0d", tname, cap_cnt, exp_n);
                errors = errors + 1;
            end else begin
                $display("PASS  %0s : target_count=%0d", tname, cap_cnt);
            end

            if (cdc_cap_cnt !== cap_cnt || cdc_cap_bus !== cap_bus) begin
                $display("FAIL  %0s : CDC mismatch (cnt %0d vs %0d)", tname, cdc_cap_cnt, cap_cnt);
                errors = errors + 1;
            end else begin
                $display("      %0s : CDC consistent", tname);
            end

            for (m = 0; m < 4; m = m + 1) used[m] = 0;

            for (s = 0; s < nsh; s = s + 1) begin
                // 期望包围盒
                ecx = sh_cx[s];
                ecy = sh_cy[s];
                case (sh_kind[s])
                    1: begin ex0 = ecx-22; ex1 = ecx+22; ey0 = ecy-22; ey1 = ecy+22; end
                    2: begin ex0 = ecx-25; ex1 = ecx+25; ey0 = ecy-18; ey1 = ecy+18; end
                    default: begin ex0 = ecx-31; ex1 = ecx+31; ey0 = ecy-20; ey1 = ecy+20; end
                endcase

                // 找中心最近的检测目标
                b  = -1;
                bd = 1 << 30;
                for (m = 0; m < cap_cnt; m = m + 1) begin
                    dcx = (f_x0(cap_bus,m) + f_x1(cap_bus,m)) / 2;
                    dcy = (f_y0(cap_bus,m) + f_y1(cap_bus,m)) / 2;
                    d   = ((dcx > ecx) ? (dcx - ecx) : (ecx - dcx)) +
                          ((dcy > ecy) ? (dcy - ecy) : (ecy - dcy));
                    if (d < bd) begin bd = d; b = m; end
                end

                if (b < 0) begin
                    $display("FAIL  %0s : shape%0d(kind=%0d) has no detected target", tname, s, sh_kind[s]);
                    errors = errors + 1;
                end else begin
                    used[b] = 1;
                    if (f_shape(cap_bus,b) !== sh_kind[s][1:0]) begin
                        $display("FAIL  %0s : shape%0d class=%0d expect %0d (ratio=%0d edge=%0d box=(%0d,%0d)-(%0d,%0d))",
                                 tname, s, f_shape(cap_bus,b), sh_kind[s], f_ratio(cap_bus,b),
                                 f_edge(cap_bus,b), f_x0(cap_bus,b), f_y0(cap_bus,b),
                                 f_x1(cap_bus,b), f_y1(cap_bus,b));
                        errors = errors + 1;
                    end else if ((f_x0(cap_bus,b) < ex0-2) || (f_x0(cap_bus,b) > ex0+2) ||
                                 (f_x1(cap_bus,b) < ex1-2) || (f_x1(cap_bus,b) > ex1+2) ||
                                 (f_y0(cap_bus,b) < ey0-2) || (f_y0(cap_bus,b) > ey0+2) ||
                                 (f_y1(cap_bus,b) < ey1-2) || (f_y1(cap_bus,b) > ey1+2)) begin
                        $display("FAIL  %0s : shape%0d box (%0d,%0d)-(%0d,%0d) expect (%0d,%0d)-(%0d,%0d)",
                                 tname, s, f_x0(cap_bus,b), f_y0(cap_bus,b),
                                 f_x1(cap_bus,b), f_y1(cap_bus,b), ex0, ey0, ex1, ey1);
                        errors = errors + 1;
                    end else begin
                        $display("      %0s : shape%0d kind=%0d class=%0d ratio=%0d edge=%0d box=(%0d,%0d)-(%0d,%0d)",
                                 tname, s, sh_kind[s], f_shape(cap_bus,b), f_ratio(cap_bus,b),
                                 f_edge(cap_bus,b), f_x0(cap_bus,b), f_y0(cap_bus,b),
                                 f_x1(cap_bus,b), f_y1(cap_bus,b));
                    end
                end
            end

            // 不允许出现多余的检测目标
            for (m = 0; m < cap_cnt; m = m + 1)
                if (!used[m]) begin
                    $display("FAIL  %0s : extra target %0d kind=%0d box=(%0d,%0d)-(%0d,%0d) edge=%0d",
                             tname, m, f_shape(cap_bus,m), f_x0(cap_bus,m), f_y0(cap_bus,m),
                             f_x1(cap_bus,m), f_y1(cap_bus,m), f_edge(cap_bus,m));
                    errors = errors + 1;
                end
        end
    endtask

    //--------------------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------------------
    integer t;
    initial begin
        sop = 0; eop = 0; valid = 0; data = 8'h00;
        nsh = 0; nnoise = 0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        $display("===============================================================");

        // 1) 单目标: 原有功能不能退化
        tname = "circle alone";            nsh = 1; nnoise = 0;
        place(0, 1);
        send_frame(1'b0);  check_frame(1);

        tname = "rectangle alone";         nsh = 1;
        place(0, 2);
        send_frame(1'b0);  check_frame(1);

        tname = "triangle alone";          nsh = 1;
        place(0, 3);
        send_frame(1'b0);  check_frame(1);

        // 2) 三个目标, 其中两个在同一水平带 (格子0/1 的 y 相同)
        tname = "3 targets, 2 same band";  nsh = 3;
        place(0, 1);  place(1, 2);  place(2, 3);
        send_frame(1'b0);  check_frame(3);

        // 3) 四个独立目标: 圆 矩 三角 圆
        tname = "4 targets";               nsh = 4;
        place(0, 1);  place(1, 2);  place(2, 3);  place(3, 1);
        send_frame(1'b0);  check_frame(4);

        // 4) 空白帧: 数量必须回到 0, 不能残留上一帧目标
        tname = "empty frame";             nsh = 0; nnoise = 0;
        send_frame(1'b0);  check_frame(0);

        // 5) valid 随机断层
        tname = "3 targets w/ gaps";       nsh = 3;
        place(0, 1);  place(1, 2);  place(2, 3);
        send_frame(1'b1);  check_frame(3);

        // 6) 孤立小噪声 (4x4=16 像素 << MIN_EDGE=80) 不能作为目标, 也不能影响真实目标
        tname = "3 targets + noise";       nsh = 3; nnoise = 6;
        place(0, 1);  place(1, 2);  place(2, 3);
        nz_x[0] =  25; nz_y[0] =  15;
        nz_x[1] = 480; nz_y[1] =  15;
        nz_x[2] =  25; nz_y[2] = 135;
        nz_x[3] = 480; nz_y[3] = 135;
        nz_x[4] = 110; nz_y[4] =  72;
        nz_x[5] = 110; nz_y[5] =  10;
        send_frame(1'b0);  check_frame(3);

        // 7) 连续多帧 三目标 -> 四目标 -> 无目标, 结果总线必须完整更新
        tname = "transition 3 targets";    nsh = 3; nnoise = 0;
        place(0, 1);  place(1, 2);  place(2, 3);
        send_frame(1'b0);  check_frame(3);

        tname = "transition 4 targets";    nsh = 4;
        place(0, 1);  place(1, 2);  place(2, 3);  place(3, 1);
        send_frame(1'b0);  check_frame(4);

        tname = "transition empty";        nsh = 0;
        send_frame(1'b0);  check_frame(0);

        tname = "transition 4 again";      nsh = 4;
        place(0, 1);  place(1, 2);  place(2, 3);  place(3, 1);
        send_frame(1'b0);  check_frame(4);

        tname = "transition empty again";  nsh = 0;
        send_frame(1'b0);  check_frame(0);

        $display("===============================================================");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $display("===============================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
