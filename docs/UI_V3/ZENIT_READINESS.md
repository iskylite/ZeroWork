# V3 → Zenit 落地核查

2026-10-25，本轮依据实际 `build.zig.zon`、`vendor/zenit/src/ui/ui.zig` 全部公共API、组件导出及相关实现核查。项目最低Zig0.17.0、Zenit本地依赖 `vendor/zenit`；不采用技能旧版0.15.2覆盖当前API。

## 判断

HTML可以作为分模块原生实施的交互与几何基准；**不能直接把DOM、CSS、iframe和定时器翻译为已经可用的原生功能**。普通表单/列表/浮层有现成组件；终端文档、视频输入、AI/任务所有权与持久化需要项目应用层实现。下表区分“现成框架能力”和“仍需接线的业务能力”，不把两者混成全部已落地。

## 组件与布局映射

| HTML设计 | 当前公开能力/项目实现 | 落地要求 |
| --- | --- | --- |
| 窗口、固定头脚、伸缩正文 | `ui.box/hstack/vstack/grid`、Sizing、BoxStyle、ScrollArea | 外壳1440×900 / 最小860×480；padding8/gap6/title46/status32/sidebar224⇄48。固定区flex_shrink=0；正文min-size与受控滚动明确，不能默认fit让头脚被挤压 |
| 输入/选择/步骤/表格 | `Input`、`Textarea`、`Select`、`Checkbox`、`Radio`、`Switch`、`Slider`、`Steps`、`Tabs`、`Table`、`Accordion` | stock Switch的track为40×22、thumb18，公开Props无size/style；V3要求30×18、thumb14，须扩公共size/recipe或复用项目已有受控小开关及其键盘/AX行为，不能缩私有thumb。Select原生options最多64项；可搜索不等于能创建任意自定义值。字体/模型自定义输入采用受控Input+Popover，长清单VirtualList，不发明allowCustom属性。使用实际builder/result API；程序set值不等于触发on_change；数值0和禁用依赖保留语义。长列表用VirtualList，不照搬全部DOM节点 |
| Tooltip/Popover/Menu/Modal/Sheet | 当前widgets及overlay portal、focus管理 | Popover支持virtual anchor、flip、viewport_padding=8、shift_main_axis、max_height；按真实globalRect取锚点，每帧/布局变更更新。Modal已有focus trap/auto_focus/restore。不得另写平行焦点系统 |
| V3颜色与状态 | `src/ui/app_theme.zig`、ThemeTokens、styled builders/recipes | 对照共享theme-tokens.css与规范§2.2；accent原色、可读ink、白字action底分别映射。换主题同步重建/更新snapshot组件，不能仅改window clear color |
| 渐变、圆角、阴影 | `Gradient`、`MultiGradient`、`ShadowList`、`InsetShadowList`、CornerRadii | CSS颜色混合/透明度在主题适配层解析，非运行CSS。普通信息/输入/菜单无描边；颜色焦点和caret反馈保持可达，不能把键盘焦点一起删掉 |
| 全局背景与半透明层次 | `GlassParams`公开backdrop blur/saturation/brightness，采样窗口自身mainRT | 根背景只绘一次；所有表面始终按全局T派生alpha=1−clamp(T×k,0,1)，k为surface1=.95/surface2=.90/well=.80/overlay=.10/hover=.75/tab=.65，不受图片开关限制；app及默认terminal承载透明。普通表面blur0、浮层局部blur B只采样下层，不复制背景或铺不透明地板。原生同尺寸同状态验证文字可读与背景连续，不承诺桌面透出 |
| 页签/分栏/拖动 | Tabs + 项目workspace/pane_manager/float_model；`ui.interaction`路由 | 稳定SessionHandle/TabId，动作冻结目标；拖序投影不复制会话，关闭/新窗口不以active或“最后一个tab”猜目标 |
| AI浮窗 | `src/ai/float_model.zig`、既有助手视图与composer | 默认600×456，最小520×354(可用边界夹取)，90px输入区；owner只读。收起继续、×停止；拖动/resize不插值命中区；Esc还原手势；历史恢复不复活旧批准 |
| KVM/VNC/RDP画面 | 未来协议renderer + 原生纹理/输入服务 | HTML BIOS/桌面是夹具；真实视频必须流纹理、等比适配与clip。指针坐标须由viewport→远端帧换算，分辨率/代际变化使旧观察与待发输入失效 |
| 本地笔记 | Textarea、Markdown、应用分栏/文件与资源服务 | HTML预览为有限子集；原生用现有Markdown组件完整语法，文件导入/相对资源复制/原子保存/失败保稿由文件服务负责 |
| 全局通知 | 项目NotificationHost/notification_presenter | 通知只消费operation事实和原owner，不在页面底部另造全局横幅；关闭通知不取消任务，点击定位不能改派发目标 |

## 终端内置命令块：必须单独实现的应用层能力

现有 `src/ui/formatted_output.zig` 只对工具输出做UTF-8/base64/JSON格式化，**不是终端文档视图**。`TerminalViewNode.showCommandMessage` 也不能替代持久命令/结果记录。HTML的垂直卡片流不能直接嵌进VT固定网格。

实施契约：

1. 每条记录至少绑定稳定owner、commandId/operationId、执行顺序、输出/错误、pending/终态及文档滚动锚点；异步完成只更新对应记录，不追随当前active。
2. 应用指令被可信输入路由捕获，不向PTY/SSH误发；普通Shell字节与原VT状态不因彩色装饰而改写。
3. 终端文档呈现层合并VT内容与应用记录；需明确换行、resize重排、滚动回看、选择/复制、搜索、导出和只读回放的归属。特殊背景可通过原生绘制/节点层表达，不能用固定底部overlay覆盖prompt。
4. 新会话连接日志属于目标会话/全局连接进度；原指令记录只保留必要的本次操作结果和定位入口。
5. 完整全屏TUI、鼠标报告和IME仍走现有TerminalSurface；不能拿普通Textarea实现VT输入。原型Textarea仅承担可编辑草稿演示。

该项是后续原生实施前必须落实的应用层设计，不应误记为已有stock widget或“只调样式即可”。

## 字体与坐标

本轮已将Inter和JetBrains Mono的官方字体资源及OFL保存在[assets/fonts](assets/fonts/README.md)，HTML通过本地@font-face加载，避免依赖本机是否安装。浏览器的font-family字符串或对不存在family的document.fonts.check=true，均不能单独证明实际字体；要结合已声明本地face加载成功与测量。

本轮读取TTF name表确认：浏览器别名`Inter`对应实际family **Inter Variable**（4.001），JetBrains Mono为2.305；不能将CSS别名`Inter`直接当作原生family。原生已有CoreText FontSystem.loadFont(path,size)、FontRegistry.intern/resolve、TextProps.font_family及实际应用字体解析。**字体随包附带不自动意味着family已注册到FontRegistry查找路径**；需加载/注册并核对实际face、字重与fallback。测量、绘制、caret、选区、命中和IME必须同一解析结果。中文使用明确fallback。

行高由绝对值换算：终端14px正文对应22/14倍率；时间戳9.5px对应14/9.5；不能把Figma22px直接填原生line_height倍率。Retina物理像素不作为逻辑尺寸；globalRect转换包括所有祖先位移与滚动。

## 状态、生命周期与系统操作

- 所有输入、回调、Node、Scope、Signal在主线程；后台只回传owner/generation/revision绑定的结果。过期结果丢弃并回收资源，不挂回新active页面。
- 页面销毁清Node/Scope引用；事件中不直接销毁仍在执行handler的子树。字符串使用setTextContent复制，避免临时缓冲悬挂。
- HTML setTimeout只模拟阶段；原生必须消费实际engine/controller事件。accepted、verifying、succeeded、failed、cancelled、unknown是不同结果；unknown只查询，不自动重发写操作。
- 系统文件选择、Keychain、系统通知权限、真实多窗口、网络重连/取消释放、KVM控制权/电源、传输续传与校验必须真实服务接入，不从HTML成功样例推导为已接通。
- 原生验收需真实窗口同状态截图、中文IME、Tab/ShiftTab/Esc/快捷键、焦点回返、滚动与VoiceOver，以及关闭/取消后资源所有权。HTML检查不能替代。

本轮不改原生程序，不以构建旧界面证明新原型已原生可用。

当前 `src/config/settings_picker.zig` 的旧权限文案及浅色surface不由HTML更新自动纠正。原生实施须检查活跃调用路径并统一主题/文案，再验同状态窗口，不能把它直接当成已与本轮一致的可复用成品。

设置效果稿默认line_height现用11/7保存完整精度；已有本地演示草稿的自选1.57不擅自改写。原生数值格式化与持久化必须区分显示舍入和真实配置，不能每次打开/保存都把精度降到两位。字体family还须与appearance_font.resolve保持64 UTF-8字节及禁止控制字符的校验。
