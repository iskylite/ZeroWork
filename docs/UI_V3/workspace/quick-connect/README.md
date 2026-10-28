# 快速连接 · 主题层级

本稿对应原生 `src/ui/quick_connect_view.zig` 与 `quick_connect_styles.zig`，只调整快速连接的视觉层级，保留点击即连接、方向键选择、Enter、Esc、搜索与临时目标语义。

## 设计合同

主要任务是快速辨认并连接目标。用稳定的输入底色、名称/地址两级排版、明确的选中底色和独立操作区建立层级，保持各主题原有色相，不增加全屏遮罩或新操作。

- 弹窗：宽 520，圆角 14，不添加常驻轮廓；向下 24、模糊 48 的主题阴影；背景沿用全局 overlay 透明度，背景模糊至少 12。
- 头部：48 高，左右 16/14，18px 原有闪电图标，标题 13/700。
- 内容：左右 16，上 8，下 16；各项间距 6。
- 输入：40 高，圆角 8，左右 12。底色为不透明 overlay 与 well 按 70:30 混合；静止态不描边，焦点态使用选中底色与 caret，不添加 border、outline 或 ring。原生采用嵌入式 `ui.widgets.Input`，由外壳绘制底色，避免全局透明 Input recipe 覆盖。
- 结果：44 高，间距 6，左右 10，20px 原有系统/服务器图标，图文间距 10。名称 13/600、行高 18；地址 11/400、行高 16，等宽。两行内容列可伸缩，不再固定名称 108 与地址 230 的列宽。跳数保留独立 46×24 标记。
- 选中：深色背景混合 accent 16%，浅色 10%；选中行不额外描边。选中行地址将 fg_2 向 fg_1 混合 12%，保持 Paper 等浅色主题可读。悬停不覆盖选中填充。
- 操作：46 高（包含按钮上方 12 间距）、通过上方留白分组，不加横向分隔线。按钮 144×34，临时目标 148×34。次操作使用不透明 popupAction，深色文字 fg_2、浅色文字 fg_1；主操作使用 action_accent 加深 2%，并根据填充选择深/浅字色，兼容原有淡靛蓝强调色。
- 最大显示 3 行，更多结果通过 Zenit `setScrollY` 公开接口滚动，避免只改状态却不更新实际位移；三行面板高 366，一行高 266。临时目标错误态高 378，860×480 窗口内完整可用。

## 浏览与测量

使用普通本地 HTTP 服务打开 `index.html`，例如从仓库根目录运行 `python3 -m http.server 8793 --bind 127.0.0.1`。支持 `?theme=midnight&count=1&t=100`，`before=1` 可查看按原生旧样式重建的参考；修改前参考并非旧版本原生截图。主题、结果数量与修改前开关位于 App 之外的评审栏。

调色板来自本项目 `theme_presets.zig`；另包含注册表中 Catppuccin Mocha、Dracula、Dark Pro、Solarized Dark、Nord 的兼容 UI 调色板，合计 17 个。原生始终读取运行时 tokens，因此导入主题也沿用同一语义规则。HTML 使用本地 Inter、JetBrains Mono、系统中文字体。它是组件样式基准，搜索/提交等业务交互以原生实现为准；本次未新增动效或改写操作文案。

浏览器实测：1280×720 CSS px，DPR 2，100% 缩放；`#palette` 一行 520×266，搜索 488×40，结果 488×44，名称/地址行高 18/16，底部 488×46。评审栏高 64，参考区域是 `#palette`，比较原生时排除评审栏与 App 壳。原生截图是 2× backing scale；视觉验收按相同逻辑尺寸比较。静止态与焦点态均不画边框，焦点通过选中底色和 caret 表达。

## 验证

- `zig build test-ui -Dui-test-filter='quick connect' -j2`：沿用现有功能用例，更新设计尺寸；主题切换用例扩展到全部 17 个注册内置主题，检查输入/选择保留、输入底色不透明及动作/选择颜色更新。
- `zig build -Dtest-mode=true --prefix /tmp/zw-quick-hierarchy/build -j2`：构建独立验收二进制，未覆盖当前用户应用。
- `node e2e/quick_connect_themes_native.ts /tmp/zw-quick-hierarchy/build/bin/zerowork /tmp/zw-quick-hierarchy/native`：17 主题、100% 全局背景透明度、960×640 实际 Metal 截图；另在 Midnight/Light/Sauber 验证第四条结果滚动、一条匹配、860×480 非法目标和无匹配、清除、Esc 与重新打开。

测试使用独立临时数据与 RPC、保留地址段夹具，不提交网络连接，不读取或改写用户配置。截图、节点几何与日志保存在 `/tmp/zw-quick-hierarchy/`。原生输入保留现有 Input 组件与 IME 门禁；本次未进行物理键盘/真实输入法或 VoiceOver 验收。局部修改由主智能体查看实际截图自检，未派独立评审，也不作视觉评分。

本轮结果（2026-10-29）：构建成功；快速连接定向测试 28/28 通过；原生 17/17 主题通过。Midnight/Light/Sauber 扩展状态通过；修正后的代表性 HTML 截图无资源错误、溢出或对比度提示。实际原生面板对比图：`/tmp/zw-quick-hierarchy/native/three-themes-single.png`；全主题图：`/tmp/zw-quick-hierarchy/native/all-17-themes.png`；机器报告：`/tmp/zw-quick-hierarchy/native/report.json`。

后续全应用巡检按用户反馈进一步收敛线条：输入焦点、结果选中、弹窗轮廓及底部均不描边；新增独立视觉复核记录与最终截图见[层级巡检记录](../../verification/layer-hierarchy-20261029.md)。上述 17 主题截图属于此前快速连接验收，最终无框版本另在午夜蓝、浅色、Sauber 复验。

全主题补验：最终输入焦点统一使用不透明的 popupSelection，避免兼容主题终端选择色降低普通输入文字可读性；17 主题标准结果原生检查均通过，详见上述巡检记录的「全部 17 个内置主题补验」。最终图集 `/tmp/zw-layer-hierarchy/all-themes/final-review/quick-all-17.png`。
