# xterm-256color 原生终端兼容性

此文记录 ZeroWork 的实现边界、复现方法与验收证据。基准是运行端实际安装的 `xterm-256color` terminfo，加上明确列出的扩展；不把 `TERM` 名称、解析器选型或编译成功当作兼容性证明。


其他内置类型的独立能力、输入矩阵与最小兼容处理见 [TERMINAL_TYPES.md](TERMINAL_TYPES.md)。

## 共用链路

- 本地 PTY 与 SSH shell 通道通过同一个 `TerminalService` 合约进入 `TerminalSurface`，使用完整 VT projection 绘制，不再把 SSH 实时画面压成行文本。
- 共用单元格/字形簇、等宽网格、调色板、RGB、反色、粗体、斜体、暗淡、隐藏、闪烁、删除线、上划线及下划线类型/颜色。应用的鼠标、按键、粘贴和焦点处理也共用。
- SSH 的 socket、PTY、输入队列、重连授权和原始记录仍由原有 worker 管理。终端回复通过唯一 SSH 写入者发送，处理部分写入/背压，不进入用户输入的重连回放队列；换连接时丢弃旧回复。
- 全局主题及默认光标形状同步到两种传输。程序的 DECSCUSR 覆盖默认值，重置后恢复用户配置。
- 开启应用鼠标跟踪时，左/中/右键和滚轮交给终端程序；Alt 可绕过应用跟踪，使用原有选择、菜单或粘贴手势。

## 能力与验证层次

| 类别 | 实际检查 |
| --- | --- |
| 终端类型 | SSH peer 记录 PTY 请求中的类型，并用请求值启动实际 ZSH；两种进程均读取 `$TERM` 和 terminfo `colors=256` |
| 字符与样式 | 原生截图检查 SGR/ACS/中文/组合字符/emoji；属性、下划线及反色另有原生节点/真实 VT 回归 |
| 颜色 | ANSI16、完整 256 色矩阵、字面黑/白、RGB；240 个扩展索引色逐项核对实际截图像素；`initc`、OSC4 查询、`oc`、`op` 回路 |
| 网格与编辑 | CUP/HPA/VPA、保存恢复、清行/清屏/ECH、插入删除字符/行、滚动区域、制表位、反向制表、REP、禁用自动折行与恢复 |
| 输入 | 普通/应用光标键、Home/End/Insert/Delete/Page、Shift-Tab、F1–F63、终端描述中的 Shift 编辑键、Ctrl/Alt、DECBKM |
| 终端回复 | 真实进程在原始模式读取 DSR 光标位置、DA 设备属性与调色板查询回复；不直接调用 VT 或伪造回复 |
| 鼠标与焦点 | 原始 PTY 验证 SGR 左/中/右键、释放和主屏滚轮字节，以及 focus-out/focus-in |
| 粘贴 | 通过系统剪贴板与 Cmd-V 验证括号粘贴；独立服务测试覆盖大于队列容量的粘贴、顺序、过期模式/确认/重连边界。测试恢复剪贴板 |
| 状态 | 主/备用屏幕恢复、DECSCUSR、真实 PTY resize、首次异步滚动和新输出下的视口保留 |
| 实际程序 | Vim Unicode 编辑保存退出、less 翻页退出、macOS top 刷新退出、tmux 分屏/输入/退出，以及 VTTEST 光标控制屏幕 |
| 生命周期 | SSH 内置命令、复合文档选择复制/搜索、正常 shell 退出和 tab 关闭的专门回归 |

测试记录能力名称、收到的字节、PNG、节点几何、运行端类型和构建 SHA-256。截图像素核对与协议断言分别记录；不把日志中的“渲染成功”当作像素证据。

## 复现

使用项目实际依赖的 Zig 0.17 和 vendored zenit。构建测试模式仅用于隔离验收，不用于发布：

```sh
zig build -Dtest-mode=true --prefix /private/tmp/zw-xterm-unified
ZW_XTERM_TMUX=/absolute/path/to/tmux \
ZW_XTERM_VTTEST=/absolute/path/to/vttest \
node e2e/xterm_capabilities_native.ts \
  /absolute/path/to/evidence \
  /private/tmp/zw-xterm-unified/bin/zerowork
```

省略最后的传输选择时依次运行 Local/SSH；可增加 `local` 或 `ssh` 单独复现。临时 SSH peer 只监听回环地址，通过 Paramiko 转发真实 ZSH PTY。需要 Python 3、Paramiko 和 Pillow。tmux/VTTEST 路径用于实际程序回归；不提供路径时这些额外程序检查不会运行，不能声称已通过它们。

```sh
zig build test-ui -Dui-test-filter=terminal --summary all
zig build test-ui -Dui-test-filter='SSH terminal service' --summary all
zig build test-local --summary all
TMPDIR=/private/tmp node e2e/builtin_records_ssh_native.ts \
  /absolute/path/to/ssh-record-evidence \
  /private/tmp/zw-xterm-unified/bin/zerowork
```

测试 Harness 仅补充了鼠标按钮与已有 KeyCode 枚举的分发能力，用生产事件分发器驱动真实窗口，不提供设置屏幕内容或注入 VT 快照的捷径。

## 边界

- `xterm-256color` 不是“所有 XTerm 私有扩展”的认证。Sixel、Tek4014、图形协议、终端打印机、窗口管理控制和操作系统权限不在此文本终端验收结论中。
- Harness 使用生产事件路径、实际 PTY/SSH 与 Metal 窗口，仍属于自动化输入；不替代实体键盘、系统输入法、VoiceOver 或所有远端系统版本的人工测试。
- 新增完整渲染路径针对实时 Local/SSH 与共用滚动文档；旧归档/历史文本帧中原本没有保存的样式不会被虚构恢复。
- 未通过的断言保持失败，不能用增加等待或修改期望来掩盖实际不兼容；测试自身的回显歧义、字符键事件类型及旧布局选择器应单独修正。
