# CODEX 项目交接摘要

> 生成日期：2026-10-26
> 项目目录：`D:\Users\Stupid2K\Documents\ChatGPT\fpga\DYC_FPGA`
> 分支：`DYC`
> 当前 HEAD：`ca5b086 checkpoint: 高阶3帧缓存冻结回放（当前黑屏待排查）`
> 远端关系：本地 `DYC` 比 `origin/DYC` 多 1 个提交
> 约束：以下总结对应现有工作区状态，没有执行覆盖、`git reset` 或回滚。

> **2026-10-26 后续排查结果：** 已独立复现并修复 DDR 写侧根因。原控制器在
> W0 FIFO 只有 1 个 128 bit 数据包时就启动 128 拍 AXI 写突发，突发中途 FIFO
> 已空仍继续写并推进地址。专项仿真曾实测 64 个输入像素却推进到
> `raw_ptr=512`、`med_ptr=384`。现改为每个突发前确认 FIFO 已有完整
> `W_BURST` 个数据包，并把 raw/median 写入严格限制为每帧
> `1280*720*2` 字节。完整 1280x720 写流已逐字校验通过。
>
> 同时修正了 `vip_rgb2gray_mult` 的乘法器端口零扩展。旧版 ModelSim 对
> 8/10 位端口直连 16 位乘法器保留 `x/z` 高位，曾使合成图端到端识别测试
> 出现 0 边缘；补齐端口后 Canny 与 Sobel 两种模式均识别通过。
>
> 顶层临时颜色条/FIFO 色块诊断均已关闭，默认恢复为 Canny 边缘、目标框和
> 中文标签；K1 长按冻结/解冻，K2 长按进入/退出 100 帧回放，K1/K2 短按
> 在实时/冻结模式继续调阈值、在回放模式翻帧。
>
> **2026-10-27 硬件诊断进展：** 已知全 1 AXI 写数据能取得 AW/W/B 响应，
> DDR 校准通过，AXI R 也能读回非零数据；黑屏的直接原因是 R0 显示 FIFO 的
> empty/valid 导致 `rframe_data_safe` 被持续置零。当前代码已加入 2048 包
> R0 FIFO、最多 4 个同 ID outstanding 读突发、串行写响应确认，并取消该
> 强制置黑路径。最新正式固件已生成，但恢复真实摄像头后的上板效果仍待验证。

---

## 1. 当前结论

项目主体功能已经实现，关键 RTL 仿真和 Efinity 全流程可以通过，但“DDR 帧缓存读回后稳定显示”仍没有完成硬件闭环验证。

最近一次明确上板现象（在 `R_BURST=32` 修复之前）是：

- 二分测试左半屏为绿色，右半屏为红色。
- 右半屏红色表示 LCD 有效显示期间 `rframe_data_valid` 为低，即显示 FIFO 被判断为空。
- 左半屏绿色来自 FIFO 空后残留的旧 `rframe_data`，不能作为有效图像使用。

因此已经确认：问题不是单纯“RGB 颜色转换把彩条变成黑色”，而是显示端 FIFO 在有效显示区没有稳定供数。

随后已经完成一项修复：

- DDR 读突发从 8 拍改为 32 拍。
- 读拍计数器从 3 位扩展为 6 位。
- 显示 FIFO 写入改为允许预取到接近满深度。

最新固件已经编译完成，但尚未获得该版本的上板结果。

---

## 2. 项目目标与技术架构

### 2.1 项目目标

目标是在易灵思 Titanium Ti60F225 FPGA 上实现一套 1280x720 实时图像处理系统，集成：

1. 摄像头原始图像采集。
2. RGB 转灰度和 3x3 中值滤波。
3. Sobel 边缘检测与可调阈值。
4. Canny 边缘检测，作为默认边缘输出。
5. 圆形、矩形、三角形目标识别。
6. 屏幕叠加目标包围框和中文标签。
7. DDR3 100 帧环形帧缓存。
8. 按键冻结当前画面。
9. 实时/冻结左右分屏对比。
10. 100 帧历史画面循环回放，并通过按键逐帧浏览。

最初要求中的默认上电状态是：

- Canny 边缘。
- 目标识别框和标签。

当前为了排查显示链路，顶层临时切换到了 DDR 颜色条诊断模式，不是最终交付状态。

### 2.2 总体数据通路

```text
CMOS 摄像头
    |
    v
RGB565 输入 + RGB 转灰度
    |
    +--> 中值滤波 3x3 --------------------+
    |                                      |
    +--> Sobel / Canny 边缘流水线          |
    |                                      |
    +--> rgb_align_ring：按像素序号对齐 <--+
    |         |
    |         +--> 16 bit {RGB555, edge}
    |         +--> 8 bit median gray
    |         |
    |         v
    |   frame_ring_ctrl
    |     - 128 bit AXI4 DDR 写入
    |     - 100 帧环形帧槽
    |     - raw / median 双平面
    |     - 冻结/回放双源读取
    |         |
    |         v
    |   R0_FIFO_16（128 bit -> 16 bit，FWFT）
    |         |
    |         v
    |   LCD/HDMI 扫描像素
    |         |
    +--> shape_recognizer -> CDC -> shape_overlay
                                  |
                                  v
                          目标框/中文标签叠加

K1/K2 -> sobel_ctrl -> 阈值、冻结、回放控制
```

### 2.3 时钟域

主要时钟及其约束频率：

| 时钟 | 频率/周期 | 用途 |
|---|---:|---|
| `cmos_pclk` | 100 MHz / 10 ns | 摄像头像素、中值、Sobel、Canny、识别 |
| `clk_sys` | 约 96 MHz / 10.417 ns | 按键控制、DDR AXI 用户时钟 |
| `clk_pixel` | 约 74.4 MHz / 13.441 ns | 1280x720@60 显示扫描、LCD FIFO 读取 |
| DDR 内部时钟 | 由 DdrCtrl 管理 | core/tac/twd/dqss 等 DDR3 控制器时钟 |

跨时钟域主要通过：

- 异步 FIFO。
- 单比特 toggle 同步。
- 每帧一次的识别结果电平握手 CDC。

### 2.4 DDR 帧布局

每个历史帧槽为 4 MiB：

| 槽内偏移 | 数据 |
|---|---|
| `0x000000` | 1280x720 个 16 bit `{RGB555, edge}` |
| `0x200000` | 1280x720 个 16 bit `{8'h00, median_gray}` |

帧槽分配：

- 槽 `0..99`：100 帧历史环形缓存。
- 槽 `100`、`101`：冻结/回放期间保存左侧实时画面的双缓冲 scratch 槽。

按 30 fps 估算，100 帧约 3.33 秒历史。

### 2.5 工作模式

| 模式 | 左半屏 | 右半屏 |
|---|---|---|
| 实时模式 0 | 整屏实时边缘 + 目标叠加 | 同左 |
| 冻结模式 1 | 实时彩色 + 红色边缘 | K1 冻结时刻的中值灰度 |
| 回放模式 2 | 实时彩色 + 红色边缘 | 当前选择的历史帧中值灰度 |

冻结/回放中，左右原始 1280x720 图通过 2x2 抽样得到 640x360 画面，再左右拼接为 1280x720，上下保留黑边。

---

## 3. 已经完成的功能

### 3.1 图像处理

- RGB565 输入转灰度。
- 3x3 中值滤波。
- Sobel 边缘检测。
- 可调 Sobel/Canny 阈值。
- Canny 边缘处理链。
- 原始 RGB、中值灰度和边缘结果按像素序号对齐。
- 32 位 AXI 写数据修正为 128 bit FIFO 输出，降低 DSP 消耗。

### 3.2 目标识别与屏幕叠加

- 圆形、矩形、三角形分类。
- 使用包围盒、边缘计数、扫描线填充面积和填充率。
- ROI 限制在画面中部的 480x360 区域。
- 识别结果从摄像头时钟域传到显示时钟域。
- 显示彩色包围框。
- 显示中文标签，包括“未识别”“检测到圆形”等。

### 3.3 按键控制

`src/sobel_ctrl.v` 已实现：

| 操作 | 当前功能 |
|---|---|
| K1 短按 | 实时/冻结模式阈值 -8；回放模式上一帧 |
| K2 短按 | 实时/冻结模式阈值 +8；回放模式下一帧 |
| K1 长按 0.8 s | 进入/退出冻结；回放模式返回实时 |
| K2 长按 0.8 s | 进入/退出 100 帧回放 |

按键具有：

- 两级同步。
- 20 ms 消抖。
- 短按在释放时确认。
- 长按只触发一次，不附带阈值步进。

### 3.4 100 帧帧环与回放

- 100 帧历史槽循环覆盖。
- 冻结/回放期间历史环暂停推进。
- 实时画面继续写入槽 100/101。
- 冻结帧和回放帧不会被新实时帧覆盖。
- 右侧历史画面使用对应物理 DDR 槽保存的目标识别元数据。

### 3.5 显示读取

- AXI4 单 outstanding 读事务。
- 按 LCD 扫描顺序读取 DDR。
- 实时模式读 raw 平面。
- 冻结/回放模式先读左侧 raw，再读右侧 median。
- 右侧回放支持 2x2 抽样。
- R0 FIFO 采用 FWFT，显示端每个有效像素读取一个 16 bit 字。

### 3.6 验证与构建

当前代码中已经存在或完成过的检查：

- 按键短按/长按策略。
- 帧槽回绕。
- 冻结保护和 scratch 槽切换。
- AXI WLAST/B response 计数。
- 缺失 B response 时的发布超时。
- 720 行显示读取地址顺序。
- 小帧写入 DDR 模型后逐像素读回。
- 32 拍 AXI 读突发的拍数和地址递进。
- Canny/中值/Sobel 与集成链路的已有回归。

---

## 4. 文件及关键改动

### 4.1 Git 当前状态

已修改但未提交：

```text
M Ti60_Demo.xml
M debug_profile.wizard.json
M docs/高阶3_帧缓存冻结回放实现.md
M example_top.v
M sim/run_sim.bat
M sim/tb_frame_ring_ctrl.v
M sim/tb_frame_ring_read.v
M src/frame_ring_ctrl.v
```

新增但未跟踪：

```text
?? sim/tb_frame_e2e.v
?? sim/tb_frame_burst32.v
```

`Ti60_Demo.xml` 和 `debug_profile.wizard.json` 的当前差异分别只是 Efinity 自动更新的时间戳/UUID，不应为了“清理 Git”而擅自回滚其它源码。

### 4.2 `example_top.v`

主要改动：

- 集成 `frame_ring_ctrl`。
- 新增 100 帧缓存、冻结、回放和显示选择连线。
- 保存目标识别框到物理帧槽元数据。
- 将默认显示源切换到 DDR 读回数据。
- 增加临时颜色条测试和显示路径诊断。
- 增加 LED 状态/自检诊断。
- 保留目标框、中文标签和识别 CDC。

当前临时诊断参数：

```verilog
FRAME_COLOR_TEST      = 1'b1;
LED_SELF_TEST         = 1'b0;
LCD_DATA_BRIDGE_TEST  = 1'b0;
LCD_TWO_PATH_TEST     = 1'b1;
LCD_LOCAL_TEST        = 1'b0;
```

`FRAME_COLOR_TEST=1` 不读取真实摄像头颜色，而是用摄像头帧有效信号生成固定颜色条：

```text
0..319    red    16'h7C00
320..639  green  16'h03E0
640..959  blue   16'h001F
960..1279 white  16'h7FFF
```

当前 `LCD_TWO_PATH_TEST=1`：

- 左半屏直接显示 DDR 读出的原始 RGB555 转换值。
- 右半屏绿色表示当前显示 FIFO 有效。
- 右半屏红色表示当前显示 FIFO 为空。

### 4.3 `src/frame_ring_ctrl.v`

核心改动：

- 100 帧 DDR3 环形缓存。
- 每帧 raw + median 两个平面。
- 冻结槽和回放槽保护。
- 左侧实时/右侧历史的双源读取。
- 写 AXI `AWVALID`、`WLAST` 和 FIFO read enable 协议修正。
- 使用真实 FIFO empty 状态，而不是过于保守的 programmable-empty。
- 增加 B response 超时，避免永久卡死。
- 增加 `rframe_data_valid` 输出。
- 显示 FIFO 允许预取到 full。
- 新增 32 拍读突发支持。
- `rd_beat_idx` 从 3 位扩展到 6 位，避免 32 拍计数回绕。

当前顶层实例显式使用：

```verilog
.R_BURST(32)
```

模块默认参数仍为 `R_BURST=8`，测试平台可覆盖。

### 4.4 `src/sobel_ctrl.v`

- K1/K2 两级同步。
- 20 ms 消抖。
- 0.8 s 长按判断。
- 短按释放触发。
- 阈值范围 0 到 2040，步进 8。
- 实时、冻结、回放状态机。
- 回放模式翻帧控制。

### 4.5 `src/rgb_align_ring.v`

- 使用块 RAM 环形延迟线。
- 按像素序号对齐，而不是按固定 `RGB_DLY` 拍数。
- 同时延迟 RGB 和中值灰度。
- 解决 valid 不连续、流水线长度变化时彩色图与边缘图错位。

### 4.6 仿真文件

| 文件 | 状态/作用 |
|---|---|
| `sim/tb_frame_ring_ctrl.v` | 已修改；验证帧槽、冻结/回放、AXI W/B、B timeout |
| `sim/tb_frame_ring_read.v` | 已修改；验证实时/冻结双源 720 行读地址 |
| `sim/tb_frame_e2e.v` | 新增；写入模型到显示读回 64/64 像素一致 |
| `sim/tb_frame_burst32.v` | 新增；验证 32 拍 burst、AR 地址和换行 |
| `sim/run_sim.bat` | 已加入 `tb_frame_e2e.v` |

注意：`tb_frame_burst32.v` 目前还没有加入 `sim/run_sim.bat` 的统一回归入口。

### 4.7 文档与工程生成文件

- `docs/高阶3_帧缓存冻结回放实现.md` 增加了 `tb_frame_e2e.v` 的回归项。
- `Ti60_Demo.xml`：Efinity 自动更新时间戳。
- `debug_profile.wizard.json`：Efinity 自动更新逻辑分析仪 UUID。

---

## 5. 当前构建产物

最新完整 flow 产物：

| 文件 | 时间 | 大小 | SHA-256 |
|---|---:|---:|---|
| `outflow/Ti60_Demo.hex` | 2026-10-26 19:31:35 | 2,403,153 bytes | `1A1F5F19AB97CBE3A3E8C5B3B54A6479ADC386B4EC7024A8B8B0CD5AC8006E2D` |
| `outflow/Ti60_Demo.bit` | 2026-10-26 19:31:35 | 2,403,093 bytes | `D237D32250A8EFBBFAC74E5555AA989BAFD7301817F31390172ED59CC79D3350` |

该构建对应当前 `R_BURST=32`、写侧完整突发确认、默认 Canny/识别和正式显示源。

当前资源使用：

- XLR：20621 / 60800，33.92%。
- Memory Blocks：104 / 256，40.62%。
- DSP：2 / 160，1.25%。

当前时序检查通过：

- 最小 setup slack 约 +0.470 ns。
- 最小 hold slack 仍为正，最低约 +0.026 ns。
- 无负时序路径。

---

## 6. 当前问题与完整硬件现象时间线

### 6.1 当前核心问题

DDR 中已经能够读到测试颜色，但显示 FIFO 不能在整个 LCD 有效区持续供数。

在 `R_BURST=32` 修复之前，二分测试明确得到：

```text
左半屏：绿色
右半屏：红色
```

其含义：

- `rframe_data` 仍保留绿色旧值。
- 同一时刻 `rframe_data_valid=0`。
- 显示的绿色不是有效数据，只是 FWFT FIFO 空时输出端残留值。

### 6.2 已观察到的上板现象

| 阶段/测试 | 观察结果 | 解释 |
|---|---|---|
| 原始 DDR 彩条 | 黑屏或无彩条 | DDR→LCD 稳定供数失败 |
| 本地 LCD 彩条 | 彩条正常显示 | `shape_overlay -> lcd_driver -> HDMI/LCD` 最终输出链可用 |
| 早期 DDR 彩条 | 偶发白闪、粉屏或黑屏 | 显示 FIFO 数据不稳定/欠载 |
| 四 LED 非零/写 FIFO/非空等诊断 | 四灯全亮但无彩条 | 曾经读到数据，不代表持续有效扫描数据 |
| 四区域通道桥接 | 白/红/绿/黄，并有整块按帧蓝闪 | RGB 位段有变化，存在帧间/读序问题 |
| 精确色匹配 LED | 四灯全部点亮 | 红绿蓝白四种精确值至少各出现过一次 |
| 右半有效、左半原始 RGB | 左绿右红 | LCD 有效期间 FIFO 为空；左绿是残留数据 |
| `R_BURST=32` | 尚未上板验证 | 当前待测版本 |

### 6.3 LED 硬件映射

板子右侧四灯实际顺序为：

```text
左 -> 右：LED3, LED2, LED1, LED0
```

LED 低有效：

- 输出 `0`：点亮。
- 输出 `1`：熄灭。

当前临时 LED 含义：

| LED | 当前条件 |
|---|---|
| LED0（最右） | 曾读到精确红色 `0x7C00` |
| LED1 | 曾读到精确绿色 `0x03E0` |
| LED2 | 曾读到精确蓝色 `0x001F` |
| LED3（最左） | 曾读到精确白色 `0x7FFF` |

这些 LED 是跨帧粘滞状态，不代表同一帧内四种颜色都完整。

---

## 7. 已尝试的解决方案

### 7.1 AXI 写协议修正

曾存在以下问题：

- `AWVALID` 设置和清除发生在同一拍，没有形成真实握手。
- `WLAST` 比最后数据拍晚一拍。
- FIFO read enable 比 AXI 读数据握手晚一拍。
- B response 计数逻辑位置错误。

已修正：

- `AWVALID` 改为组合条件 `wstate == W_ADDR`。
- `WLAST` 改为当前拍组合判断。
- FIFO read enable 与 AXI 写握手同拍。
- B response 计数从 reset 分支移出。
- 增加 B response 超时。

### 7.2 FIFO 状态判断修正

原来使用 programmable-empty 作为“是否有完整数据”的判据，过于保守。

已改为真实 FIFO `empty` 状态，并在显示 FIFO 上增加 `rframe_data_valid`。

### 7.3 显示 FIFO 预取与安全显示

曾尝试：

- 使用 programmable-full 标记限制 FIFO 预取。
- 后改为允许预取到 full。
- FIFO 空时把像素替换为黑色。
- 通过 `rframe_data_valid` 在屏幕右半屏显示绿色/红色。

结果：

- 安全替换证明了 FIFO 在有效显示区为空。
- 但也导致纯黑屏，因为残留数据被彻底屏蔽。

### 7.4 显示位段桥接诊断

曾把 RGB555 位段直接映射为固定颜色：

- 非零 → 白色。
- 红通道非零 → 红色，否则蓝色。
- 绿通道非零 → 绿色，否则洋红色。
- 蓝通道非零 → 蓝色，否则黄色。

结果观察到白/红/绿/黄及按帧蓝色闪烁，说明四种精确颜色确实能被读到，但扫描时序/供数仍不稳定。

### 7.5 32 拍突发修复

原显示读路径：

- `R_BURST=8`。
- 每 8 个 AXI beat 就结束一个 burst。
- 然后重新等待 AR 握手和 DDR 读延迟。
- `rd_beat_idx` 只有 3 位，无法表示 0..31。

当前修复：

- 顶层显式 `R_BURST(32)`。
- `rd_beat_idx` 改为 6 位。
- 单 burst 从 64 像素提升到 256 像素。
- 保留单 outstanding 读事务结构。

新增 `tb_frame_burst32.v` 验证：

- 1280 宽一行需要 5 个 32 拍 burst。
- 两行共 10 个 AR。
- 每个 AR 的 `ARLEN=31`。
- 地址每次递增 512 字节。
- 行切换地址为 2560 字节。

测试结果：全部通过。

---

## 8. 遇到过的完整报错

### 8.1 仿真端口类型错误

原始错误：

```text
# ** Error: (vsim-3053) tb_frame_ring_read.v(164): Illegal output or inout port connection for "port 'rframe_data'".
# Region: /tb_frame_ring_read/dut
# Error loading design
```

原因：

- `frame_ring_ctrl.rframe_data` 是 `output wire`。
- 测试平台把 `rd_data` 声明成了 `reg`。

修复：

- 将 `tb_frame_ring_read.v` 中的 `reg [15:0] rd_data` 改为 `wire [15:0] rd_data`。

### 8.2 新增 valid 端口后的测试警告

新增 `rframe_data_valid` 后曾出现：

```text
Too few port connections. Expected 65, found 64.
Missing connection for port 'rframe_data_valid'.
```

修复：

- 在 `tb_frame_ring_ctrl.v`、`tb_frame_ring_read.v`、`tb_frame_e2e.v` 中显式连接该端口。

### 8.3 历史 `display_mode_frame` 多驱动错误

`outflow/Ti60_Demo.err.log` 中仍保留早期构建失败的记录：

```text
[EFX-0010 VERI-ERROR] net 'display_mode_frame[1]' is constantly driven from multiple places
[EFX-0010 VERI-ERROR] found another driver here
[EFX-0021 ERROR] Elaboration of module 'example_top' failed.
```

说明：

- 这是旧日志中的历史错误。
- 当前 `example_top.v` 中 `display_mode_frame` 只保留一个时序驱动块。
- 2026-10-26 最新完整构建已经通过 elaboration、PnR 和 timing。

### 8.4 32 拍测试平台的初始失败

第一次运行 `tb_frame_burst32.v` 时，测试模型把 `RLAST` 提前一拍置高，导致：

```text
[FAIL] two rows issue five 32-beat bursts each
[FAIL] reader reaches the final display row
[FAIL] second burst advances by 512 bytes
[FAIL] fifth burst ends row 0
[FAIL] next row starts at 2560 bytes
```

原因：

- 测试平台 BFM 的 `RLAST` 生成条件在阻塞递增之后判断，提前一拍结束。
- RTL 的 6 位 `rd_beat_idx` 本身没有错误。

修复：

- BFM 改为在 `beat` 递增后判断 `beat == R_BURST-1`。
- 随后 7 项检查全部通过。

### 8.5 Efinity 非致命警告

Efinity 命令启动时会出现：

```text
WARNING: cannot find correct IV value
```

该警告未阻止 map、PnR、timing 或 bitstream 生成。

---

## 9. 可能根因

### 9.1 已确认或高可信根因

1. **显示 FIFO 在 LCD 有效扫描期欠载**

   左绿右红是直接证据：

   - 右侧红色来自 `frame_data_valid=0`。
   - 左侧绿色来自 FIFO 空后未更新的旧输出。

2. **8 拍小 burst 的 AR/读延迟开销过高**

   每 8 拍就重新发 AR，DDR 读延迟不能充分摊销，可能无法达到每像素时钟持续供数。

   `R_BURST=32` 是针对该问题的当前候选修复，但仍需上板验证。

3. **32 拍支持必须有足够宽的拍计数器**

   原 `rd_beat_idx` 只有 3 位；直接改成 32 拍会在第 8 拍回绕。该问题已修复并有专项仿真。

### 9.2 尚未验证的猜测

1. **单 outstanding AXI 读仍然不够**

   即使 burst 扩展到 32 拍，每次仍需等待完整 burst 返回，再发下一次 AR。如果 DDR 控制器在读写竞争下读延迟较大，仍可能供数不足。

2. **DDR 写入长期占用仲裁带宽**

   写路径每次使用 128 拍突发，读路径是单事务。DDR 控制器仲裁可能对读侧不够友好。

3. **FIFO 跨时钟域 full/empty 同步边界的预取余量不足**

   当前 R0 FIFO 为 512 x 128 bit，显示侧等效 4096 个 16 bit 像素。即使允许 full 预取，异步指针同步仍可能造成短时欠载。

4. **R0 FIFO 的 8 像素组顺序可能反向**

   `R0_FIFO_16` 当前 `ENDIANESS=0`，而写侧先从低 16 bit 开始打包。需要单独验证读回时 8 像素组是否被反向。

   该问题即使存在，通常表现为每 8 像素块左右反向或局部错位，不足以单独解释 FIFO 完全为空，但在供数恢复后必须检查。

5. **帧诊断图案本身依赖摄像头有效时序**

   `FRAME_COLOR_TEST` 虽然替代了颜色数据，但每帧起始、valid 计数、SOP/EOP 仍来自摄像头流水线。如果摄像头帧边界或有效像素数量不稳定，诊断图案相位也可能变化。

6. **显示 FIFO 复位和新帧启动之间仍有残留事务**

   每个 LCD VSYNC 会复位显示 FIFO，并通过 toggle 让 DDR reader 重新开始扫描。若上一帧仍有在途 AXI 读响应，理论上可能在新帧 FIFO 中混入旧数据。

7. **显示端 valid 只由 FIFO empty 推导**

   `rframe_data_valid = !rfifo_empty` 是正确的初步判据，但没有结合当前 `rd_active`、reader 行号和 LCD 坐标做完整跨时钟域校验。

---

## 10. 下一步建议

### 优先顺序

1. **上板验证当前 17:56 固件**

   使用：

   ```text
   outflow/Ti60_Demo.hex
   ```

   在 Programmer 中重新选择该文件，避免使用缓存路径。

   当前屏幕仍为二分诊断：

   - 右半屏绿色：FIFO 在有效显示区正常供数。
   - 右半屏红色：仍然欠载。
   - 绿色/红色交替：吞吐处于临界状态。

2. **如果右半屏仍然红色**

   优先把 DDR 读改成多 outstanding 请求，例如：

   - 2 到 4 个读请求槽。
   - AR 命令 FIFO。
   - 每个 outstanding 使用独立 ID。
   - 用每槽 expected beat 计数重组返回数据。

   目标是隐藏 DDR 读延迟，而不仅是增加单次 burst 长度。

3. **增加 FIFO 状态可观测性**

   建议临时用逻辑分析仪或 LED 编码观察：

   - `rfifo_empty`
   - `rd_datacount_o`
   - `rd_state`
   - `axi_arready`
   - `axi_rvalid/ready`
   - `out_y`
   - LCD `lcd_de`

   这样可以量化欠载发生在帧首、行首还是持续供数不足。

4. **确认 32 拍读回的 8 像素顺序**

   在供数稳定后，先显示一帧每个 8 像素组递增的测试图案，确认 R0 FIFO 的 `ENDIANESS` 和写侧 128 bit 打包顺序一致。

5. **把 `tb_frame_burst32.v` 加入统一回归**

   在 `sim/run_sim.bat` 中：

   - 编译 `tb_frame_burst32.v`。
   - 增加对应 `vsim` 步骤。

6. **恢复正式显示功能**

   硬件供数通过后，将临时诊断关闭：

   ```verilog
   FRAME_COLOR_TEST     = 1'b0;
   LCD_TWO_PATH_TEST    = 1'b0;
   LCD_DATA_BRIDGE_TEST = 1'b0;
   LCD_LOCAL_TEST       = 1'b0;
   ```

   并恢复正式 LED 指示，而不是精确色匹配粘滞 LED。

7. **完整回归与实机验证**

   至少执行：

   - `tb_sobel_ctrl`
   - `tb_frame_ring_ctrl`
   - `tb_frame_ring_read`
   - `tb_frame_e2e`
   - `tb_frame_burst32`
   - `tb_edge_system`
   - `tb_display_overlay`
   - 全量 `sim/run_sim.bat`
   - Efinity full compile

8. **通过后再提交**

   当前所有调试改动尚未提交。建议硬件确认稳定后：

   - 检查生成的 `Ti60_Demo.xml` 和 `debug_profile.wizard.json` 是否应排除。
   - 将 32 拍修复和新测试作为独立提交。
   - 不要 `git reset --hard` 或覆盖当前改动。

---

## 11. 关键运行命令

### ModelSim 定向编译

工作目录：`sim`

```powershell
& 'D:\altera\13.0\modelsim_ase\win32aloem\vlog.exe' `
  -work work +define+DYC_FRAME_STUB_FIFOS +incdir+..\src `
  ..\src\frame_ring_ctrl.v `
  tb_frame_ring_ctrl.v tb_frame_ring_read.v tb_frame_e2e.v tb_frame_burst32.v
```

### 关键仿真

```powershell
& 'D:\altera\13.0\modelsim_ase\win32aloem\vsim.exe' `
  -c -do "run -all; quit -f" work.tb_frame_burst32
```

### Efinity 完整构建

工作目录：项目根目录

```powershell
& 'D:\Efinity\2025.1\bin\efx_run.bat' `
  Ti60_Demo --prj -f compile --timeout 1800
```

### Programmer 文件

```text
D:\Users\Stupid2K\Documents\ChatGPT\fpga\DYC_FPGA\outflow\Ti60_Demo.hex
```

---

## 12. 特别注意事项

1. 当前 `FRAME_COLOR_TEST=1`，上电不会显示真实摄像头图像。
2. 当前 `LCD_TWO_PATH_TEST=1`，屏幕不是最终画面。
3. 当前四颗 LED 是精确测试色粘滞指示，不是正式模式/阈值指示。
4. 最新 `R_BURST=32` 固件尚未收到上板结果。
5. 左半屏出现绿色时，如果右半屏为红色，绿色是 FIFO 空后残留值。
6. 不要把四颗精确色 LED 全亮解释成“同一帧四色都正确”；它们只表示跨帧曾匹配过。
7. 构建前确认 Programmer 选择了最新时间戳的 hex，历史排查中曾出现旧 hex 路径残留。
8. 现有未提交源码是继续排查的基础，不应覆盖或回滚。
