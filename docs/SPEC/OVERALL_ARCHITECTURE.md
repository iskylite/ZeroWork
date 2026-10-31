## 0. 当前落地入口

> 仓库清理说明：历史原始图像、日志和快照已移除；相关证据链接统一指向脱敏状态摘要，不表示原始逐项材料仍保存在仓库。

性能子版本补丁：[V0.1.8.1 终端交互延迟与资源占用](V0.1.8.1_PATCH_TERMINAL_PERFORMANCE.md)。

2026-10-23起实施顺序是先做[插件宿主](../DESIGN/V0.2_PLUGIN_HOST.md)，再考虑[BMC iKVM](../DESIGN/V0.3_BMC_IKVM.md)。KVM设计依据曙光SuperPod / AST2600 / BMC 1.80实机，采用SSH跳板上的HTTPS/WSS、OEM认证与RFB扩展、zenit原生像素工作区及Redfish电源/启动项；不含媒体挂载。它覆盖下文历史“KVM仅规划/先做电源”表述，但不是V0.2的子版本，当前只保留设计和原型。现有静态注册表与terminal/file宿主仍是闭枚举，下文“新协议零改动主程序”仅为早期目标，不能作为当前源码事实。

0.2 插件接入：三项内置能力保留实现并统一注册；公共侧栏/顶栏/Tab/底栏/AI/设置按标准贡献适配，插件内容页完全定制。插件 ConnectionEditor/Controller 在宿主承载内自主组织配置与连接，schema 仅可选辅助；只复用已保存配置，不复用活跃会话/运行转发，每个新会话独立建链。0.2 主要补后端及必要公共 UI 接线；零宿主业务改动限于已发布 API，新增依赖须显式登记。详见插件宿主§1–6、§8及 KVM§3–5、§11。

2026-10-18起，以[实施设计路线](../DESIGN/README.md)为唯一落地顺序：V0.1.1–V0.1.8每版先非UI、再UI；通用规则统一见[设计规范](../DESIGN/DESIGN_STANDARDS.md)。当前确认页Figma与已确认用户决定优先，Local ZSH、SSH、独立SFTP及原型内全部状态属于首版。全局主题同时作用应用和全部终端，无单会话覆盖。

本文保留早期SPEC与日期化原型记录供追溯；其中旧47图、单会话主题覆盖、P0–P8进度、示意API和未来协议工期等不能覆盖当前设计。不作为新版本自动通过证明。

## 本轮 Figma 原型（2026-10-13 · 待评审）

当前设计与行为契约见[版本实施设计](../DESIGN/README.md)及[设计规范](../DESIGN/DESIGN_STANDARDS.md)；本节余下为2026-10-13的历史记录。本轮不替换原始效果图和 HTML；继续在已有本地 Figma 文件调整。此前项目内的.fig、HTML 索引和旧验证记录不能代表本轮最新状态。

- [直接进入首页的预览](https://www.figma.com/proto/FOPeYuvmCL86rgev6Niobz/ZeroWork?node-id=1-4&starting-point-node-id=1%3A4&page-id=0%3A1&scaling=min-zoom)
- [可编辑 Figma 文件](https://www.figma.com/design/FOPeYuvmCL86rgev6Niobz/ZeroWork?node-id=1-4)

默认主题按用户提供的 Sauber.itermcolors 精确提取；APP 与终端使用统一主题。原型统一顶栏、侧栏和状态栏，选择控件使用就地浮层，新增主机使用三步向导。AI 助手绑定会话或组，模型返回工具目标；不提供人工切换执行目标的 UI。当前未实现子智能体。

本轮同步更新了 AI 所有权、历史、上下文与工具计划契约代码。原型仍使用预填数据；完整工具执行循环、原生鼠标键、剪贴板、系统文件选择和最终 Zenit UI 对齐不能通过 Figma 点击验收。构建与测试结果、工具接入缺口详见上述契约，不把原型成功状态视为真实远程执行。

# 原生 macOS SSH 终端模拟器总体架构与工程实现规范 (ZeroWork SPEC)

> **版本**：v3.1-Production Draft
> **编写时间**：2026-10-08
> **技术栈基准**：Zenit 原生 macOS UI（Metal Retained Node） | Headless VT (libghostty-vt / libvterm) | **Zig 0.17.0（由本地 zvm 固定，构建说明见 docs/GUIDES/DEVELOPMENT.md）** | libssh2 1.11+ / mbedtls 3.x | macOS 14.0+ (Apple Silicon)

> **UI 实现边界**：应用界面统一直接使用 Zenit。Zenit 自身负责 macOS 原生窗口、输入与 Metal 平台集成；ZeroWork 不另写 Objective-C/Swift UI 桥接层，也不维护平行的 AppKit/SwiftUI 视图树。
> **文档体系（当前执行入口）**：
> - **本文档**：原产品规格与架构决策来源，保留历史上下文。
> - **[实施设计路线](../DESIGN/README.md)**：唯一版本顺序、非UI/UI边界、需求归属和完成门槛。
> - **V0.1.1–V0.1.8各版本正文**：按基础宿主→本地终端→SSH→SFTP/传输→终端增强与历史→组与转发→AI→整合发布排列；每版同时包含该域模型、接口、异常、UI精数、配置及验收。
> - **[设计规范](../DESIGN/DESIGN_STANDARDS.md)**：唯一非版本通用补充，规定主题/token、控件、动效、Zenit适配、线程安全和验证。
> - ****：569逻辑key/558状态/三主题1674根逐项映射；历史47图仅供参考。
> **目录结构**：`docs/SPEC/`保存原规格与原型来源；`docs/DESIGN/`保存实施入口、8个功能版本、单份设计规范及证据。
> **目标**：纯 Zig + Zenit 单一 Metal 管线的企业级 SSH 终端 = 多跳 SSH / SFTP 传输 / 终端组广播 / **AI 远程运维辅助（浮窗式一等公民）** / 可扩展协议插件（FTP / VNC / RDP / KVM）。

---

## 1. 架构决策全景 (ADR)

- **ADR-01 纯 Zenit 单一 Metal 管线**：整个 App 仅一个 CAMetalLayer / 一个 RenderPass；终端网格为 Zenit 原生 `TerminalViewNode`（CustomDraw 直出 DisplayList）。杜绝多层 NSView 嵌套的 Resize 抖动、毛玻璃透光、IME 焦点错乱。
- **ADR-02 解耦 Headless VT 引擎**：抽象 `VtEngine` 接口；首选 libghostty-vt（vendoring 锁 commit），备选 libvterm。
- **ADR-03 线程模型**：UI 主线程 / SSH I/O Worker（kqueue）/ SFTP 传输 Worker 三者分离；SPSC 无锁环形队列 + 高低水位背压（85%/30%）。
- **ADR-04 协议插件化**：`ProtocolPlugin` 三件套（Session / RenderNode / Transfer）。首发 SSH+SFTP；FTP 纯 Zig 自研（P6）；VNC 自研 RFB 3.8（P7）；RDP 走 FreeRDP FFI（P8）；KVM 先 Redfish REST 电源管理（P8）。
- **ADR-05 AI 浮窗式一等公民**：AI 以**顶部液态玻璃边条 + 悬浮窗**嵌入会话页，基于**远程服务器上下文**，经**独立 exec channel** 执行诊断，权限模式可选，写操作强制确认。
- **ADR-06 传输与会话物理隔离**：SFTP 使用**独立 TCP/SSH 连接**（复用同一跳板链），大文件传输与终端交互零相互阻塞（§5.4）。

---

## 2. UI/UX 设计总规范与全部页面效果图

### 2.0 浮层统一设计规范（所有浮窗/弹窗/抽屉/HUD/设置页必须遵循）

**A. 主题一致配色（浮层必须派生自当前主题 token，禁止体系外颜色）**
```
overlay.bg:      color-mix(theme.bg 94%, #FFFFFF)  → Sauber 下 = rgba(248,255,251,.95)
                 + backdrop-filter: blur(24px) saturate(1.2)
overlay.border:  1px solid color-mix(theme.accent 10%, transparent)
overlay.shadow:  0 16px 44px rgba(15,23,42,.14), 0 2px 8px rgba(15,23,42,.06)
overlay.radius:  12px (卡片) / 8px (控件)
设置页底:        color-mix(theme.bg 96%, #FFFFFF)  → #F7FFFB；侧栏 nav 底 = #EFF9F2
文字:            theme.fg #0F172A / 次 #475569 / 弱 #94A3B8
强调/语义:       accent #1345F6 · 成功 #10B981 · 警告 #D49A0C · 危险 #DC4C3F
动效:            展开 180ms ease-out (0.98→1 + 透明度过渡)；收起 140ms ease-in
换主题时:        浮层随主界面同步换色（同一 token 源），暗色主题自动得到暗色浮层
```

**B. 浮窗锚定规则（不偏离原则）**
```
AI 浮窗:        锚定当前会话 Pane 的顶部中央 (pane-local, 非 window-global)
                Pane 移动/缩放/分栏变化时浮窗跟随重定位；窗口失焦不漂移
链路弹层:       锚定状态栏 ProxyJump 胶囊正上方，**指向小三角中心必须落在胶囊水平中心**（触发点即锚点，误差≤2px）；空间不足自动翻转/内缩 8px
@指令面板:      锚定当前 Pane 中心；HUD 类锚定 Pane 中心
Tab 中键菜单:   锚定被点 Tab 下方左对齐；贴近右边缘时右对齐
全局约束:       所有浮层 clamp 在窗口内容区内 (min margin 8px)；跟随窗口 resize 实时重算
锚定通则:       **任何浮层的视觉锚点（三角/边缘）必须与触发它的控件几何对齐**；实现验收以效果图同尺寸 diff 为准
```

### 2.0b 设计落地对齐规范（实现必须逐像素对齐效果图）

```
栅格:          4px 基础网格；组件内边距取 4 的倍数 (8/12/16/20/24)
标题栏:        高 40px；Tab 高 28px 圆角 7px；图标位 30×28px
状态栏:        高 28px；字号 11px；分隔线 1×14px
侧边栏:        展开 224px / 折叠 48px；分组标题 10px 大写；行高 30px
终端:          字号 14px JetBrains Mono；行高 1.5 (=21px)；内边距 10/14px；时间戳 gutter 宽 66px
AI 状态浮条:   100×14 透明梯形（只容三点），Pane 顶边居中内嵌；展开浮窗宽 600
浮层:          圆角 12px；内容 padding 20-24px；标题 14px/600；正文 12-12.5px
按钮:          主按钮高 34px 圆角 8px padding 9×26px；次按钮 9×18px
输入框:        高 32px 圆角 8px 边框 var(--bd) 聚焦时 accent 2px ring
开关:          34×19px 圆点 15px；chip 下拉: 高 26px 圆角 7px 后缀 " ▾"
验收:          实现稿与效果图同尺寸截图 diff，结构间距误差 ≤2px
```

### 2.0c 窗口缩放自适应策略（效果图 mockup-resize.png）

| 窗口宽度 | 行为 |
| :--- | :--- |
| ≥1280px | 完整布局：侧栏 224px + 终端 + 状态栏全项 |
| 1100~1280px | 侧栏保持，状态栏隐藏低优先级项（编码/尺寸） |
| <1100px | **侧栏自动折叠为 48px**（用户 ⌘B 展开的偏好优先于自动） |
| <900px | 分栏 Pane 达到最小宽 320px 后启用横向滚动指示；AI 浮窗宽度随 Pane 收缩 (min 420px) |
| 高度 <480px | 状态栏隐藏；AI 边条保持；浮窗最大高度 = 窗口高-48px 内部滚动 |

- 终端网格随窗口实时 reflow（列数变化 → VT 重排，软换行重新计算；OSC 133 保护命令行）
- 所有浮层按 §2.0B 锚定规则在 resize 中实时重定位，**禁止漂移/出界**
- Resize 期间渲染降帧策略：连续 resize 时终端 60fps 节流，松手后恢复 120Hz ProMotion。

### 2.1 主框架

**主工作区（侧栏展开 · 合并式标题栏）**

标题栏与 Tab 合并单行 40px；右侧图标区 ⚡⌘K / ⇅传输 / ✨AI⌘J / ⚙⌘,；状态栏 `ProxyJump` 胶囊**可点击查看通信链路**（见 §2.6）。

**侧栏折叠态（⌘B · 48px 图标栏）**

⌘B 在 224px 展开 ⇄ 48px 图标栏间切换；折叠态 hover 图标显示主机详情气泡，最大化终端面积。

**窗口缩放自适应（<1100px 自动折叠侧栏）**

窄窗口下：侧栏自动折叠、状态栏低优先级项隐藏、AI 浮窗锚定 Pane 顶部中央不偏移（§2.0c）。

**Tab 中键菜单（右键 = 粘贴）**

右键打开页签菜单：重命名/新建同主机会话 @new/镜像复制 @dup/编辑连接配置/查看跳板链路/会话主题/开启 SOCKS5 转发/页签颜色/加入终端组/显示时间戳/导出会话日志/关闭其他/断开并关闭；中键 = 直接关闭页签；双击 = 内联重命名。

**⌘K 快速连接**

Spotlight 风格：模糊搜索 + 分组徽标 + 最近连接；底部支持 `user@host:port` 即兴直连，⌘↵ 在新分栏打开。

**断线自动重连**

顶部横幅（不占终端文本平面）：点名中断跳板、倒计时、⌘R 立即重连；VT 网格与滚动历史完整保留；5 次失败后保留现场可 @log 复原。

### 2.2 终端增强

**左侧时间戳 + 矩形块选 + 历史回溯**

时间戳为最左列 gutter，与命令行垂直对齐、不参与复制；⌥+拖拽矩形块选跨行不强制整行；顶部时间轴滑杆进入只读历史回溯（RawStreamTap 重放）。当前提示符输入行整行相对高亮（accent 6% 底 + 左缘 3px 竖条，见 mockup-main/terminal-enhance），设置 `ui.input_line_highlight` 可关。

**命令自动补全（App 级）**

ghost-text 内联建议（frecency = 频率 × 时间衰减），→ 接受；⌘; 全量菜单带来源徽标（历史/路径缓存/内置表）；纯本地预测零延迟，与远端 tab 补全正交，可开关。

### 2.3 内置指令（@ · 行首触发）

**@ 指令菜单**

键入 `@xx` 实时过滤（只列匹配项 + 底部计数「共 N 条匹配」）；单独键入 `@` 回全量 14 条；菜单锚光标行下方，超高时内部滚动。

**触发规则：仅提示符行缓冲区为空时键入 `@` 生效**；`@` 前有空格或文本（如 `echo @up`）、全屏程序（vim/htop）中均不触发；`@@` 转义字面 @。

**@up 上传**

`@up [本地路径]` → **统一传输面板（上传模式，与拖拽/⌘U 同组件）**；省略路径弹出文件选择（最近使用下拉 + macOS 原生选择器，支持多选/目录）；远程目录默认跟随终端当前目录。

**@dl 下载**

`@dl <远程路径> [本地目录]` → **统一传输面板（下载模式）**：保存目录可选（默认 ~/Downloads）、**文件名可重命名**、来源链路标注，↵ 即走 SFTP 独立连接。

**@grp 终端组**

`@grp k8s-nodes` → 创建/加入终端组；Tab 角标与 Pane 边框同步染组色，提示其他会话加入方式。

**@new 基于当前主机新建会话**

`@new` → 按当前会话的主机配置新建会话（走其启动命令）；**当前会话在终端组内时新会话自动入组**；链路凭据内存复用，无需二次认证。

**@dup 复制（镜像）当前会话**

`@dup` → 镜像当前会话状态：同主机 + 自动 `cd` 到当前目录（OSC 7 同步）；与 `@new` 的区别是 @new 为全新初始化、@dup 携带现场；组内同样自动入组。

**@help 指令速查**

全部指令一览浮层 + 触发规则说明。

**@ai → AI 浮窗**（见 §2.4）· **@sync → 广播**（见 §2.5）· **@ts / @log → 终端增强**（见 §2.2）

### 2.4 AI 辅助（浮窗式 · 远程语境）

**收起态：44×10 迷你状态胶囊（三点状态机）**

Pane 顶边居中内嵌 100×14 透明梯形，只容三个状态点。待机=微光；执行中=蓝青紫轮转；成功=绿 3s；失败=红常亮；待确认=琥珀呼吸。hover / 点击 / `@ai` / ⌘J 展开。

**展开态：悬浮窗（权限模式 + 模型配置 + 远程文件附加）**

- 助手归属只读显示：活动会话或活动会话组；模型调用决定组内目标；📎 附加远程文件（SFTP 路径选择器，头部 4KB 注入上下文）
- 权限仅两档：**确认后执行（默认）/ 自动执行(白名单)**。只读命令两种模式都自动执行；黑名单任何模式仅可复制
- 模型 chip 在输入条右侧（provider / model / effort）；上下文按模型窗口计量，不单独配置行数
- 明示：**所有上下文与命令均作用于远程服务器，AI 不接触本机文件系统**
- Esc 收缩回边条；诊断走远端独立 exec channel，不占用交互终端。

### 2.5 终端组与广播

四宫格组色描边 + 底部广播条（成员 chips、⌘⇧I/@sync 开关）；AI `exec_group` 整组扇出并聚合 diff。

### 2.6 文件传输与链路查看

**拖拽上传 HUD（纯 SFTP · 信息分层）**

链路面包屑（本机→Bastion-01→VPC-Transit→DB-Master）+ 引擎能力 chips（独立传输连接 · 不占用终端 / 16×64KB 窗口 / 断点续传）。

**状态栏 ProxyJump 胶囊点击 → 通信链路弹层**

逐跳展开：地址/端口、登录用户、密钥算法、单向 RTT 与端到端累计、在线状态；节点详情统一复用，重新连接会重建完整链路。底部保留测试全链路、复制链路报告、编辑配置入口。

**传输管理器**

队列 + 速度曲线 + 暂停/恢复/重试 + MD5 校验状态 + 多跳链路标注。

**SSH 双因素动态验证码（2FA/OTP）**

密码/密钥通过后出现 keyboard-interactive 挑战 → 6 位动态码模态（TOTP 30s 倒计时环）；可配置 `totp_secret` 本地 RFC 6238 自动填码仅需确认；跳板链任意一跳可独立要求 OTP（§5.6）。

**交互式密码 / 密钥口令 / 主机密钥确认（统一认证模态框架）**

除 OTP 外，password auth、加密私钥口令、known_hosts 首连 TOFU 指纹确认均复用同一模态框架（§5.6 五类交互表）。“保存到 hosts.toml” 为首版明文方案的显式勾选。

### 2.7 连接配置

**ProxyJump 多级跳板拓扑向导**

**新建连接（多协议插件 + 启动命令）**

协议选择（SSH/SFTP 首发、FTP/VNC Beta、RDP/KVM 规划）+ 启动命令序列（`cd /opt/deploy` 等按序注入，支持 expect-send 对）。

**三步向导的串联（同一模态内，不关闭不重开）**：顶部步骤条常驻「1 基本信息 → 2 跳板（可跳过）→ 3 确认」，当前步加粗高亮；步骤 1 底栏为「取消 / 下一步」，步骤 2 为「上一步 / 下一步」，步骤 3 为「上一步 / 重新测试 / 保存并连接」。三步共用一份草稿状态，来回切换不丢已填内容。

**跳板是可选的**：步骤 1 的「跳板（可选）」默认为「不使用 · 直连目标」。直连时点「下一步」仍会经过步骤 2（只显示"不使用跳板"提示，可立即再点下一步），保证三种连接路径的确认页结构一致——确认页（mockup-connect-confirm）摘要行显示「跳板：无（直连）」，测试只跑单跳。

### 2.8 设置（8 页全量）

**外观与主题**（主题卡片 + 字重 Light/Regular/Medium/Bold 真实变体）

**快捷键**（可重录制；含鼠标交互约定）

**SSH 与网络**（保活/超时/重连退避/输入缓存回放）

**文件传输**（独立传输连接/共享通道限速/窗口/续传/MD5）

**AI 辅助**（provider/endpoint/key/model/effort/context/权限模式/脱敏/Ollama）

**协议插件**（SSH/SFTP 已启用；FTP/VNC Beta；RDP/KVM 规划）

**通知**（传输完成/断线重连/AI 就绪/Bell/勿扰时段）

**数据与日志**（明文配置警示/环形缓冲/快照间隔/导出/清空）

---

## 3. Zenit 终端渲染管道

### 3.1 三阶段批量光栅化（背景 RLE 合并 → 整行 text_run+TextSpan → 选区/光标覆盖层）

### 3.2 字重渲染（真实变体，非合成加粗）
```zig
pub const FontSet = struct { regular: ui.FontHandle, bold: ui.FontHandle,
    italic: ui.FontHandle, bold_italic: ui.FontHandle };
// 设置提供 Light/Regular/Medium/Bold 基准字重; SGR bold → 升一级字重渲染
```

### 3.3 时间戳 Gutter（**左侧列**，与命令行垂直对齐）
- VT 行结构 `received_at_ms: u64`；渲染为视口**最左列** gutter（宽 64px），与文本行同基线对齐
- Gutter 不参与命中测试与选择模型（Selection 只引用文本网格），复制零污染；@ts on|off 切换。

### 3.4 选择模型
- stream（默认）/ block（⌥+拖拽矩形）；双击选词、三击选逻辑行（软换行拼接）；复制去除尾随空白。

---

## 4. Headless VT 引擎与内存拓扑

紧凑 Cell 16B 对齐（codepoint4+fg4+bg4+attrs2+extra2，comptime assert）；滚动历史 1024 行/页 PageList 双向链表；行级 `received_at_ms` 时间戳；**RawStreamTap**：PTY 字节流原样 tee 到环形磁盘缓冲（默认 64MB/会话），供历史回溯与崩溃恢复重放。

---

## 5. SSH、多跳隧道、传输隔离与断线重连

### 5.1 连接时序（同前）：TCP → 外层 SSH → direct-tcpip → 内层 SSH → PTY/Shell，逐跳嵌套。

### 5.2 SPSC 背压（同前）。

### 5.3 多跳下 SFTP：`libssh2_sftp_init` 于最内层 Session，天然穿透 N 跳；UI 标注链路。

### 5.4 ★ 传输与会话物理隔离（需求：上传是否占用会话/大文本阻塞分析）
**问题**：libssh2 在同一 TCP 连接上多路复用 channel。SFTP 大数据块与交互 shell channel 共享一个 TCP 流，内核缓冲区被 SFTP 写满时，终端击键/回显包排队 → 出现"传大文件时终端卡顿"（TCP 级 HoL 阻塞）。
**方案（默认开启）**：
```
会话连接 (TCP#1): SSH Session A ── shell channel(交互) + AI exec channel(轻量)
传输连接 (TCP#2): SSH Session B ── sftp subsystem(大块数据)   ← 复用同一跳板链, 认证凭据复用
```
- SFTP 引擎独立建立第二条连接（跳板隧道逐跳重建，凭据内存复用，无二次交互）
- 命令行回显与文件传输物理隔离，**上传/下载永不阻塞会话**
- 兜底：若服务端限制 `MaxSessions`/`MaxStartups` 导致第二连接失败，自动降级为同连接 SFTP + 分块限速（pacing 64KB/10ms），并在传输卡片标注"共享通道·限速中"
- 配置：`transfer.dedicated_connection = true`、`transfer.shared_pacing_kbps = 2048`。

### 5.5 ★ 断线自动重连状态机
```
CONNECTED ──keepalive 超时/EOF──> SUSPECTED (横幅: "连接中断, 检测中…")
SUSPECTED ──1s/2s/4s/8s 指数退避自动重连(上限5次)──> RECONNECTING (横幅倒计时: "3s 后第 2/5 次重连 [⌘R 立即] [关闭]")
RECONNECTING ──成功──> CONNECTED (toast "已重连", VT 网格/滚动历史/当前目录保持不变, 终端追加 ── reconnected 14:22:31 ──)
RECONNECTING ──5次失败──> DEAD (横幅: "重连失败 [重试] [保留现场查看日志] [关闭]")
任意态: ⌘R 立即重连; 重连期间输入缓存, 恢复后回放(可关)
```
- 重连复用 RawStreamTap：失败时可通过 @log 复原断线前完整屏幕与滚动历史
- 跳板链逐跳健康度分别标识（哪一跳断了在横幅上点名，如 "Bastion-01 无响应"）。

### 5.5b ★ 历史回滚查看：断线 / 会话结束两个场景

**场景 A · 连接异常断开**：终端画面冻结在断线前最后一刻（VT 网格与全部滚动历史保留），顶部重连横幅；期间可自由滚动/复制/搜索；`@log` 进入时间轴回放查看任意历史片段（RawStreamTap + 30s VT checkpoint 重放）。

**场景 B · 会话已结束**（远端 exit / 对端关闭 / 认证失败放弃）：页签进入**只读墓碑态**：

- 终端内容完整保留只读可滚动/复制/搜索；光标消失，输入不再发送
- 顶部横幅：`⏹ 会话已结束 · exit 0 · 14:32:07` + `[↻ 重新连接]` `[📜 回溯历史]` `[✕ 关闭]`
- `@log` / ⌘⇧F 照常可用；墓碑态不产生新日志写入
- Tab 关闭后仍可从「数据与日志」按会话导出历史（RawStreamTap 落盘保留期内）
- 组会话中单个成员结束不影响组，Pane 边框变灰标注。


### 5.6 ★ 认证体系：密码 / 密钥口令 / 双因素动态码（统一交互模态框架）

**认证协商顺序**：`publickey（含 agent/证书）→ password → keyboard-interactive`，任一返回 partial success 则进入下一阶段；三类交互统一走同一「认证模态框架」（效果图 mockup-otp.png / mockup-auth-pwd.png）：

| 交互类型 | 触发 | 模态内容 |
| :--- | :--- | :--- |
| 服务器密码 | `password` auth 或 keyboard-interactive 提示 "Password:" | 密码框（暗文）+ ☐保存到 hosts.toml（明文,600）+ 取消/连接 |
| 私钥口令 | 加载加密私钥失败 | Key 名称 + 口令框 + ☐本次会话记住（仅内存） |
| 动态验证码 OTP | keyboard-interactive 提示 code/otp/token | 6 位分格 + TOTP 倒计时 + 可选自动填充 |
| 主机密钥首连 (TOFU) | known_hosts 无记录 | 指纹 SHA256:… + 算法 + 「信任并保存 / 仅本次 / 拒绝」 |
| 主机密钥变更 | 与 known_hosts 不符 | **红色警告模态**，必须输入 yes 确认，提示 MITM 风险 |

- 实现：password → `libssh2_userauth_password`；keyboard-interactive → `libssh2_userauth_keyboard_interactive` 回调按 prompt 文本分流（password/code 复用不同模态模板）
- 多跳场景每跳独立认证状态机，任意跳可要求上述任一交互；已完成跳不因后续跳重试而失效
双因素（PAM: Google Authenticator / Duo / 堡垒机动态口令）流程：
```
password/publickey 认证 → 服务端返回 "partial success"
  → keyboard-interactive 挑战 ("Verification code: ") → 用户输入 6 位 TOTP → 认证完成
```
- **实现**：`libssh2_userauth_keyboard_interactive(session, &prompt_callback)`；回调解析 prompt 文本（匹配 `code|otp|verification|token` 关键词）→ 抛事件到 UI 线程弹 OTP 模态；连接中的页签显示"等待二次验证"态
- **OTP 模态**（效果图 mockup-otp.png）：6 位数字分格输入、TOTP 30s 倒计时环、自动提交（输满即发）
- **可选 TOTP 自动填充**：`hosts.toml` 存 `totp_secret`（明文，首版接受）→ 内置 RFC 6238 TOTP 生成器（HMAC-SHA1，~100 行 Zig，无外部依赖）自动填码，用户仅需点确认；也可关联 macOS 密码管理器手动粘贴
- **多跳场景**：跳板链中任意一跳可独立要求 OTP，模态标题点名当前验证的跳（如 "Bastion-01 二次验证"）；链路建立状态机为每跳保留独立 auth 子状态
- **失败处理**：验证码错误 → 服务端重发挑战，模态原地重试（不清空已建立的已完成跳）；连续 3 次失败终止并回报；超时 60s 未输入视为放弃。

### 5.7 ★ 状态栏链路查看（ProxyJump 胶囊可点击）
- 状态栏 `⬡ ProxyJump` 胶囊为可点击控件 → 弹出**通信链路弹层**（统一浮层规范，向上锚定，效果图 mockup-linkchain.png）
- 弹层内容：**新建主机、核对测试、新会话进度、通信链路使用同一个横向拓扑组件**（本机→跳板→…→目标），卡片固定显示名称、地址端口、身份和状态；详细诊断按需展开，不为不同入口另外绘制一套节点。在线、验证通过且已释放、连接中、失败分别为状态变体；不提供后端不支持的“只重连此跳”
- 底部操作：测试全链路（逐跳 TCP+Auth 探测并刷新 RTT）、复制链路报告（文本）、编辑连接配置
- 断线状态下弹层自动点名故障跳（红色高亮）并给出一键重连
- 直连会话胶囊显示 `⬡ Direct`，点击弹出单跳详情。

### 5.8 ★ 多层 ProxyJump 技术可行性与稳定性分析

**结论：技术完全可行，N 跳无协议层上限；稳定性取决于逐跳健康治理，本设计已内建。**

**原理**：SSH `direct-tcpip` channel 是透明的 TCP 字节管道。第 i 层 SSH Session 的 socket 由第 i-1 层 Session 上的 direct-tcpip channel 承载，逐层嵌套（俄罗斯套娃）。libssh2 对此无深度限制——每层只是"换了个 fd"的全新 SSH 握手。

**各层开销（实测经验值）**：
| 项 | 每跳成本 | 说明 |
| :--- | :--- | :--- |
| 延迟 | +5~30ms | 取决于地理距离；加密在终点 CPU，逐跳加解密开销 <1ms |
| MTU | 每跳 SSH 包头 ~28-52B 嵌套 | 深链路建议链路 MTU clamp（ssh channel 分包天然规避 IP 分片问题） |
| 建连时间 | +0.3~1s | 每跳完整 SSH 握手（密钥交换+认证）；**并行预建+凭据复用可压缩** |
| 内存 | ~2MB/跳 | 每层 SSH 状态机 + 窗口缓冲 |

**稳定性风险与对策（均已纳入设计）**：
1. **任一跳断 = 全链断** → §5.5 断线重连状态机按跳定位故障点。认证挑战仍在进行时保留本次已建立的前序跳；本次尝试最终失败或取消后逆序释放全链路。重试使用新的 attempt ID，从入口重新建立完整路径，不承诺故障段替换或复用已释放的健康跳
2. **中间跳 MaxSessions/MaxStartups 限制** → 隧道 channel 计入 session 数；对策：控制每跳并发 channel ≤8，超限排队；传输独立连接失败时自动降级共享通道（§5.4）
3. **逐跳 keepalive 漂移** → 每跳独立应用层 keepalive（默认 30s），避免 NAT 表项超时；keepalive 超时才判定该跳 SUSPECTED，不误判慢链路
4. **深度建议**：UI 层 `jump_chain` 软上限 8 跳（可配），超出弹警告——不是不能跑，而是故障定位与延迟体验显著劣化
5. **环检测**：配置保存及运行时连接入口均验证端点、端口、用户与环（A→B→A），在网络 I/O 前拒绝非法路径。

### 5.8.1 新会话连接进度与日志（2026-10-14）

新会话连接立即打开共用进度弹窗，日志默认折叠；直连、单跳、多跳沿用同一模块。包括第几跳、主机和阶段，日志展开后显示事件顺序与错误码。前序失败导致未连接的节点显示“前序失败”，不能伪装成该节点自身认证失败。

- 阶段：TCP 连接 / direct-tcpip 隧道 / SSH 握手 / 主机密钥 / 身份认证 / shell / 就绪。用户确认主机密钥、密码、私钥口令和 OTP 属于当前尝试，不跳过原有安全流程。
- 成功：最终目标 SSH 就绪且控制器完成会话接入后自动关闭；Figma 中的 0.8 秒成功反馈仅为演示，不是网络超时策略。
- 失败：保留摘要与日志，提供重试、关闭。重试创建新 attempt，重建整条链路；旧 attempt 的迟到事件不能修改新尝试。
- 取消：发出取消并等待后台清理；检查取消后不得再打开下一跳隧道。关闭弹窗不改变其他现有会话。
- 日志只记录端点、时间、阶段、状态和错误码，不记录密码、私钥、口令或 OTP。
- 配置中的“测试连接”仍留在验证步骤，不隐式保存、不打开终端，成功后释放测试通道；“保存并打开”再进入新会话进度弹窗。

本轮只补充 SSH 后端进度接口及诊断缓存，没有接入原生 UI；Figma 状态为示例数据。

### 5.9 ★ SOCKS5 动态端口转发（ssh -D 等价 · 内建本地代理）

**功能**：任一会话可一键开启本地 SOCKS5 监听，把本机任意 App（浏览器/curl/包管理器）的 TCP 流量经 SSH 链路从**远端出口**出网。

**实现**：纯 Zig RFC 1928 服务端（~350 LOC，无第三方依赖）：
```
监听 127.0.0.1:<port> (kqueue, 注册进统一事件循环)
  → 握手(no-auth) → 解析 CONNECT(cmd=0x01) 目标 host:port
  → 在「出口跳」的 SSH Session 上 open direct-tcpip(host,port)
  → 本地 socket ⇄ channel 双向 relay（splice 式转发, 零拷贝缓冲 32KB）
  → 任一侧 EOF/ERR → 双侧关闭, 计数回收
```

**多跳支持范围（明确语义）**：
| 项 | 结论 |
| :--- | :--- |
| 多跳是否支持 | **完善支持**——SOCKS5 只是末端（或指定跳）Session 上的 direct-tcpip channel，链路几跳都能用，与 `ssh -J a,b -D` 同机制 |
| 默认出口 | **链路末端**（目标主机）；流量从最后一跳出网 |
| 可选出口 | 出口节点选择器可指定**任一已认证跳**（如只到 Bastion 出网）；@new/传输第二连接同样可选 |
| 协议限制 | **仅 TCP CONNECT**；UDP ASSOC 拒绝并回复 0x07（SSH channel 无 UDP 语义）；BIND 不支持 |
| 资源占用 | 每条代理连接 = 出口跳 1 个 channel，计入该跳 sshd MaxSessions（治理同 §5.8）；单监听并发软上限 64 |
| 绑定地址 | 默认 **127.0.0.1**（仅本机）；改绑 0.0.0.0 需红色二次确认（把代理暴露给局域网的风险提示） |
| 生命周期 | 会话断开 → 监听暂停（保留端口，横幅提示）；重连成功自动恢复；会话关闭 → 监听释放 |

**可配置项**（连接配置「🔀 端口转发」区 + 信息卡「改端口/出口」转发配置模态）：

| 配置项 | 默认 | 说明 |
| :--- | :--- | :--- |
| 本地端口 | 1080（冲突自动 +1 探测） | 1-65535 |
| 绑定地址 | 127.0.0.1 | 改 0.0.0.0/局域网 IP 需红色二次确认（代理暴露风险） |
| 出口节点 | 链路末端 | 可指定任一已认证跳（HopSelector） |
| 连接时自动开启 | 关 | 开启后建连成功即起转发（含自动重连恢复） |
| 并发软上限 | 64 | 防中间跳 MaxSessions 打满 |

**★ 四种场景的入口设计（转发与会话生命周期解耦）**：

| 场景 | 入口 | 机制 |
| :--- | :--- | :--- |
| ① 会话已打开，临时开转发 | `@socks on [端口]` / Tab 右键「🧦 开启 SOCKS5 转发」/ 状态栏 | **复用当前 SSH 连接**开 direct-tcpip，秒开无需重连；配置未预置也可直接用（参数走默认值） |
| ② 会话已打开，想持久化配置 | 信息卡「改端口/出口」→ 转发配置模态 → ☐保存到主机配置 | 即时生效 + 可选写回主机配置 |
| ③ 不开终端、仅要转发 | **侧栏主机右键「🧦 仅开启 SOCKS5 转发」** | 建立**后台转发会话**：完成认证但不分配 PTY/终端 Tab；侧栏行显示 `🧦:1080` 标记，右键可停止/打开终端；状态栏显示「后台转发 ×N」 |
| ④ 主机未配置转发且未连接 | 侧栏右键菜单同一项（③）即可——配置不是前置条件；或先进入「新建/编辑连接」预配置并开「自动开启」 | 后台转发会话同样支持跳板链与全部认证模态 |

- 后台转发会话计入会话注册表但**无 RenderNode/无 Tab**；其断线重连复用同一状态机（恢复后转发自动可用）

**★ 转发状态显示矩阵（到处可见、状态可辨）**：
| 位置 | 显示 | 状态语义 |
| :--- | :--- | :--- |
| 状态栏 chip | `🧦 SOCKS5 :1080 ● 3` | 端口 + 实时活跃连接数；点击开信息卡 |
| 状态栏（断线） | `🧦 :1080 ◌ 已暂停` 灰色 | 宿主会话断线：监听保留、新连接即拒；重连自动恢复绿点 |
| Tab 标题 | 会话名前 `🧦` 前缀 | 该前台会话挂着转发 |
| 侧栏主机行 | `🧦:1080 后台` 徽标 | 后台转发会话（无 Tab）；前台会话挂转发显示 `🧦:1080` |
| 状态栏右侧 | `🧦 后台转发 ×N` | 全局计数（N>0 才显示），点击列出全部转发并可停止 |
| 信息卡 | 监听/出口/活跃连接/累计流量/协议范围 + 测试/复制/改配置/停止 | 详见 mockup-socks5.png |
- 转发随其宿主会话（前台 Tab 或后台转发会话）关闭而释放
---

## 6. 文件传输体系（纯 SFTP · 统一传输面板）

**三入口复用同一「传输确认面板」组件**（效果图 mockup-at-up / mockup-at-dl / mockup-dragdrop 即同一面板的不同模式）：

| 入口 | 面板模式 | 预填内容 |
| :--- | :--- | :--- |
| 拖拽文件入终端 | 上传 | 源文件=拖入项（多选/目录）；远程目录=终端当前目录 |
| `@up [本地路径]` | 上传 | 带参→直填路径；**无参→弹出文件选择**（最近使用下拉 + macOS 原生 NSOpenPanel 多选） |
| `@dl <远程路径> [本地目录]` | 下载 | 远程文件直填；**保存目录可选（默认 ~/Downloads）+ 文件名可重命名** |
| ⌘U / 传输管理器 [+] | 上传 | 空白待填 |

- 引擎统一：滑动窗口 16×64KB + ACK 补窗；断点续传；**MD5 默认关**（大文件免全量哈希，开启后不一致重传末块一次再报错）；完成 macOS 通知
- **同名冲突默认每次询问**，绝不静默覆盖。询问卡为纵向单选，默认不预选，未选时「继续」禁用（效果图 mockup-conflict.png）：跳过、另存为带时间戳的新文件、双方保留、覆盖。覆盖放在最后且用危险色。批量可勾选「剩余同名文件也按此处理」
- 传输执行全部走独立传输连接，面板只是参数收集层。

---

## 7. 协议插件标准接口设计（当前版本范围：仅 SSH / SFTP / AI）

> **范围锁定**：初版仅交付 SSH + SFTP + AI 辅助。FTP / VNC / RDP / KVM / Markdown 知识库均为**后续方向，不在本次设计范围**（效果图仅作远期占位展示）。但插件接口必须**现在就标准化定型**，保证后续协议零改动主程序接入。

```zig
// proto/plugin_interface.zig —— 协议插件标准契约（v1 冻结）
pub const PluginManifest = struct {
    id: []const u8,            // "ssh" | "sftp" | 未来 "ftp"/"vnc"/...
    version: u32,              // 接口版本, 不兼容升级 +1
    display_name: []const u8,
    capabilities: Caps,        //.terminal.file_transfer.video.power_mgmt
};
pub const ProtocolPlugin = struct {
    manifest: *const fn  PluginManifest,
    createSession: *const fn (alloc: Allocator, cfg: HostConfig, rt: *Runtime) anyerror!*Session,
    createRenderNode: ?*const fn (*Session) anyerror?*ui.Node,   // 终端/VNC 帧缓冲
    transfer_engine: ?*const fn (*Session) anyerror?*TransferEngine, // SFTP 类
    destroy: *const fn (*Session) void,
};
pub const Session = struct {   // 统一会话契约
    write: *const fn (*Session, []const u8) anyerror!void,
    onOutput: *const fn (*Session, *const fn ([]const u8) void) void,  // 输出回调进 SPSC
    resize: *const fn (*Session, cols: u16, rows: u16) anyerror!void,
    close: *const fn (*Session) void,
    health: *const fn (*Session) Health,   // rtt_ms, state, hop_detail?
};
```
- 生命周期/线程约束/背压与 SSH 相同（ADR-03）；错误码统一 `ProtoError` 枚举
- 新协议接入 = 实现契约 + 注册表登记，不改 app/vt/ui 任何代码；传输类插件自动复用统一传输面板与管理器。

## 8. AI 辅助子系统（浮窗式 · 远程运维语境）

### 8.1 定位与设计约束
- **AI 辅助一切基于远程服务器**：上下文采集、命令执行、文件读取全部发生在远端主机，AI 不接触本地 Mac 文件系统
- **远程运维助手**：内置工具受助手所有权、会话成员与权限限制；当前不支持子智能体
- 相对于**当前页面**：单会话页 → 作用于该会话；终端组页 → 绑定该组，模型选择组内目标（单个或多个）。

### 8.2 浮窗 UX（嵌入而非割裂）
- **收起态**：Pane 顶边居中 **100×14 透明梯形**，只容三点。待机 accent 35% 微光；回合执行中蓝→青→紫轮转 1.2s；成功绿常亮 3s 后回待机；失败/中止红常亮直到下次交互；有待确认命令时琥珀呼吸。不占布局
- **唤起**：hover / 点击 / `@ai [问题]` / ⌘J
- **展开态**：顶部居中悬浮卡片（宽 600，统一浮层规范），Esc 或把手收起；焦点自动还给终端。

### 8.3 浮窗内控件（效果图 mockup-ai-float.png 已完整呈现）
1. **只读助手归属**：显示当前活动会话或活动组，不提供作用范围下拉；每个 owner 分别保存对话与草稿。模型调用必须返回 `session_ids`，只允许 owner 内目标；远程文件与命令遵循相同规则，置顶只影响摘要顺序
2. **远程文件附加**：📎 唤起远端路径选择器（走 SFTP 目录缓存），选中文件头部 4KB 注入上下文（日志排障场景）
3. **权限模式**（输入条左侧 chip，仅两档，会话级记忆）：
   - `✋ 确认后执行`（默认）：只读命令自动跑，写操作出确认卡
   - `⚡ 自动执行(白名单)`：白名单模板自动跑；组执行时强制降回确认后执行
   - 黑名单（rm -rf /、mkfs、dd of=/dev、fork 炸弹）任何模式只可复制。不设只读诊断档，也不设第四档「自定义」。
4. **输入区两行布局**（参考主流 Agent；控件全部 22px 图标级，不挤压输入；效果图 mockup-ai-float.png）：
   ```
   行1: [ 多行输入框（自动增高，⌘↵ 换行 / ↵ 发送）                    ]
   行2: [＋] [✋▾ 权限]                    [◔ 23%] [🟣 sonnet-4·中 ▾] [➤]
   ```
   - **权限 chip**（图标+迷你文字）：点击只弹出两档（✋确认后执行✓默认 / ⚡自动执行·白名单）
   - **上下文用量环 ◔：按当前模型上下文窗口计量**（模型绑定，非独立配置项）——hover 明细 "23% · 46k / 200k tokens（claude-sonnet-4 窗口）· 终端 200 行 + 2 文件"；终端采集行数随模型窗口自动缩放（≈窗口 5%），设置页不再单独配置
   - **模型 chip**：`图标+短模型名·effort ▾`，点击弹按 Provider 分组的选择浮层（含各模型上下文窗口标注）；effort 段点击在已启用等级间循环
   - **`/` 前缀**：弹远程文件选择浮层（SFTP 缓存；远程引用保留来源身份，读取目标由模型指定），选中注入文件头部 4KB
   - **多行输入**：⌘↵ 软换行，输入框 1~6 行自动增高，超出内部滚动。
5. 对话区：流式输出、exec 工具卡（命令+截断输出+exit code）、工具计划卡（目标与参数只读；批准此调用/拒绝/复制）。

### 8.4 执行通道（独立 exec channel）
同一 SSH Session 上 `libssh2_channel_exec` 开独立通道：不污染交互终端、精确捕获 stdout/stderr/exit code、可与 shell 并发；组模式按模型指定的组内目标执行并聚合结果。AI 输出**永不直接写入 PTY**；每次调用先校验 owner 与目标，再经过权限判定；写操作按规则审批。

### 8.5 上下文采集（全部远端）
最近 N 行输出（VT 转储去控制序列）、OSC 133 命令块历史、主机指纹（连接后一次性 `uname -a; cat /etc/os-release; uptime; df -h | head` 缓存）、OSC 7 当前目录、📎 附加远程文件头部；发送前可预览/脱敏（IP/主机名掩码开关）。

### 8.6 入口汇总
顶部边条 hover/点击 · `@ai 问题` · ⌘J · 选中文本中键菜单"问 AI" · 命令非零退出轻提示 `✨ 退出码 1 · 问问 AI?`（可关）。

---

## 9. 内置指令与命令补全

### 9.1 ★ @ 指令触发规则（严格）
- **仅当终端处于提示符行编辑态、且行缓冲区为空时，键入的第一个字符为 `@` 才进入指令模式**
- `@` 前已有任何文本或空格 → 视为普通字符直送远端（如 `echo @up`、` @up` 均不触发）
- 全屏程序（vim/htop/tmux alt-screen）活跃时不拦截，字节直通
- `@@` 转义字面 `@`。

### 9.2 指令表（客户端本地执行，不进远端 shell）
| 指令 | 语义 | 效果图 |
| :--- | :--- | :--- |
| `@up [本地路径]` | 统一传输面板·上传（**省略路径弹文件选择**：最近列表+原生选择器多选） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@dl <远程路径> [本地目录]` | 统一传输面板·下载（**保存目录可选 + 重命名**，默认 ~/Downloads） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@ai [问题]` | 展开 AI 浮窗（可带问题） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@grp <组名>` | 当前会话加入/创建终端组 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@new` | 基于当前主机新建会话；**在组内则自动入组**；凭据复用免二次认证 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@pin` | 在终端组内置顶/取消置顶当前会话（组摘要优先成员；不决定 AI 执行或远程文件目标） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@socks on\|off [端口]` | 当前会话 SOCKS5 动态转发开关（默认 1080；出口=链路末端） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@theme [名称]` | 会话级主题切换（无参弹选择浮条；default 恢复全局） | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@dup` | 复制（镜像）当前会话：同主机 + 自动 cd 当前目录（OSC 7）；组内自动入组 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@sync on\|off` | 广播输入开关 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@ts on\|off` | 时间戳 gutter 开关 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@log` | 历史回溯模式 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| `@help` | 指令速查浮层 | [HTML 状态索引](../UI_V3/SCREENS.md) |

### 9.3 App 级命令补全（可开关，不依赖远端 tab）
- **数据源三级融合**：本会话历史（frecency = 频率 × 时间衰减排序）+ SFTP 路径缓存 + 内置静态表（~500 常见命令/子命令/flag）
- **两级呈现**：输入即出 **ghost-text 灰色内联建议**（`→` 接受 / `Esc` 忽略）；`⌘;` 弹全量候选菜单（带来源徽标：历史/路径/内置，显示匹配片段高亮）
- 纯本地预测、零延迟、离线可用；不发送任何控制序列干扰远端；设置 `completion.enabled` 开关
- 效果图：mockup-completion.png。

---

## 10. 终端组与广播输入
`TerminalGroup{id,name,color,members,broadcast}`；广播时焦点 Pane 击键 fan-out 全组（修饰键仅焦点，提供"仅文本广播"模式）；Pane 2px 组色描边 + 底部广播状态条；AI `exec_group` 复用组成员（§8.4）。

---

## 11. 启动命令、日志回溯与会话恢复
`startup_commands = ["cd /opt/deploy", "source ~/.envrc", "ll"]`（shell 就绪后按序注入，支持 expect-send 对）；RawStreamTap + 30s VT 快照 checkpoint → `@log` 时间轴滑杆只读回放；断线后可复原断线前完整屏幕；导出.txt /.cast (asciinema v2)。

---

## 12. 键盘/鼠标交互规范

### 12.1 快捷键总表
| 快捷键 | 功能 | 快捷键 | 功能 |
| :--- | :--- | :--- | :--- |
| ⌘T / ⌘W | 新建/关闭标签 | ⌘K | 快速连接 |
| **⌘B** | **侧边栏 展开⇄折叠（48px 图标栏）** | ⌘R | 立即重连当前会话 |
| ⌘D / ⌘⇧D | 垂直/水平分栏 | ⌘] / ⌘[ | 切换 Pane |
| ⌘1..9 | 按序号直达页签 | ⌘J | AI 浮窗展开/收起 |
| ⌘U | 上传 HUD | ⌘; | 命令补全菜单 |
| ⌘F / ⌘⇧F | 终端搜索 / 历史回溯 | ⌘⇧I | 广播输入开关 |
| ⌘C / ⌘V | 复制/粘贴（无选区时 ⌘C 透传 SIGINT） | ⌘⇧V | 粘贴并剥离别名换行（防注入） |
| ⌘+ / ⌘- / ⌘0 | 字号 | ⌥+拖拽 | 矩形块选 |
| ⌘, | 设置 | Esc | 关闭浮层/退出回溯 |

### 12.3 快捷键与终端原生按键冲突策略

**分层原则：⌘(Cmd)=App 层快捷键；⌃(Ctrl)=终端/Shell 层，永远直通远端**。两层零交集：
| 按键层 | 归属 | 示例 |
| :--- | :--- | :--- |
| ⌘ 系 | ZeroWork App | ⌘T/⌘K/⌘J/⌘B/⌘; …shell 从不使用 ⌘，无冲突 |
| ⌃ 系 | 远端 shell/程序 | ⌃C SIGINT、⌃D EOF、⌃U kill-line、⌃R 历史搜索 —— **全部原样透传** |
| 裸键/Fn | 远端 | 方向键/Home/F1-F12 透传 |

**两个特判（用户习惯优先）**：
0. **补全采纳键不与终端冲突**：ghost-text 用 `→` 采纳（fish 风格）；`Tab` 是 shell/zsh 补全的肌肉记忆键，**永远透传远端**，App 补全不占用
1. `⌘C`：有选区 → 复制；**无选区 → 透传为 ⌃C (SIGINT)**；设置项 `keys.cmd_c_mode = "smart" | "copy_only" | "signal_only"`
2. `⌘V`：始终粘贴（多行时触发注入防护确认）；`⌘⇧V` 剥离换行粘贴。

**潜在习惯冲突说明**：⌘K（macOS Terminal=清屏）此处为快速连接——终端清屏仍可用 `⌃L`/`clear`；⌘R（部分终端=清滚动区）此处为立即重连——均不影响远端行为，仅 App 层语义重定义，可在设置-快捷键中重录制。

### 12.2 ★ 鼠标交互规范（三套菜单职责严格区分，效果图三张）

| 菜单 | 触发 | 职责域 | 内容（仅列） | 效果图 |
| :--- | :--- | :--- | :--- | :--- |
| **Tab 页签菜单** | Tab 右键 | 会话生命周期与配置 | 重命名 · 新建同主机会话(@new) · 镜像复制(@dup) · 编辑连接配置 · 查看跳板链路 · 页签颜色 · 加入终端组 · 时间戳开关 · 导出会话日志 · 关闭其他 · 断开并关闭 | [HTML 状态索引](../UI_V3/SCREENS.md) |
| **Terminal 文本菜单** | 终端区中键 | 文本/视图操作 | 问 AI(附选中) · 复制 · 粘贴 · 矩形块选模式 · 时间戳开关 · 历史回溯 · 终端搜索 · 导出选中 | [HTML 状态索引](../UI_V3/SCREENS.md) |

| **侧栏主机菜单** | 主机行右键 | 主机资产管理 | 新标签连接 · 新窗口连接 · 复制配置(克隆) · 修改配置 · 查看历史会话日志 · 置顶分组 · 移动分组 · 删除主机 | [HTML 状态索引](../UI_V3/SCREENS.md) |

> 区分原则：Tab=会话实例、Terminal=文本内容、侧栏=主机资产；**复制/粘贴/问 AI 只出现在 Terminal 菜单**，连接/配置只出现在 Tab 与侧栏菜单，零职责重叠。Tab 中键=直接关闭（不弹菜单）。

**触发方式明细**：

**Tab 页签**：
- **左键**：切换；左键拖拽：排序；**双击**：重命名内联编辑
- **右键**：页签菜单（重命名/新建同主机会话 @new/镜像复制 @dup/编辑连接配置/查看跳板链路/页签颜色/加入终端组/显示时间戳/导出日志/关闭其他）（效果图 [HTML 状态索引](../UI_V3/SCREENS.md)）
- **中键**：**直接关闭页签**（浏览器惯例）。

**Terminal 区域**：
- **右键**：有选区 → **复制**；无选区 → 粘贴（⌘V 同效）
- **中键**：终端上下文菜单（问 AI/复制/粘贴/矩形块选模式/时间戳开关/历史回溯/导出选中）（效果图 [HTML 状态索引](../UI_V3/SCREENS.md)）
- ⌥+拖拽：矩形块选；双击选词；三击选逻辑行。

---

## 13. 配置与数据存储（首版纯明文）
```toml
# ~/.zerowork/config.toml
[ui]    theme = "sauber"; font_family = "JetBrains Mono"; font_size = 14; input_line_highlight = true
        font_weight = "regular"        # light|regular|medium|bold (真实变体)
        line_height = 1.5; cursor_style = "block"; sidebar_collapsed = false
[completion] enabled = true
[transfer] dedicated_connection = true; window_chunks = 16; chunk_kb = 64
           download_dir = "~/Downloads"; verify_md5 = false; shared_pacing_kbps = 2048
[ssh]    keepalive_sec = 30; reconnect_max = 5; reconnect_backoff = [1,2,4,8,16]
[ai]     default_provider = "anthropic"
         permission_mode = "confirm"  # confirm|auto（浮窗输入区 chip 可临时切换）
         redact_ip = false; error_hint = true

# 多 Provider：列表管理，可新增；模型按 provider 归属，effort 等级逐模型配置
[[ai.providers]] id = "anthropic"; endpoint = "https://api.anthropic.com"; api_key = "sk-..."
  [[ai.providers.models]] name = "claude-sonnet-4"; default = true
    efforts = ["low","medium","high"]            # 该模型启用的等级（low/medium/high/xhigh/max 子集）
    reasoning = true                             # 是否支持推理模式
    context_window = 200_000                     # ★ 上下文窗口是模型属性（模型绑定），用量环按此计量
  [[ai.providers.models]] name = "claude-haiku-4"
    efforts = ["low","medium","high"]; reasoning = false; context_window = 200_000
[[ai.providers]] id = "openai-compat"; endpoint = "https://your-gateway/v1"; api_key = "..."
  [[ai.providers.models]] name = "gpt-5-mini"; efforts = ["low","high"]; reasoning = true; context_window = 128_000
[[ai.providers]] id = "ollama"; endpoint = "http://localhost:11434"   # 本地全离线
  [[ai.providers.models]] name = "qwen3-32b"; efforts = ["low"]; reasoning = false; context_window = 32_768
[log]    ring_mb = 64; checkpoint_sec = 30

# ~/.zerowork/hosts.toml
[[hosts]] name = "K8s-Node01"; host = "10.200.1.18"; port = 22; user = "ubuntu"
          auth = { key = "~/.ssh/id_ed25519", passphrase = "..." }  # 或 { password = "..." }
          jump_chain = ["bastion-01"] ; group = "Production" ; totp_secret = "JBSWY3DPEHPK3PXP"  # 可选 2FA 自动填充
# 主机配置支持「复制」：侧栏主机行 hover 显示 ⧉ 按钮 / 新建连接对话框顶部「从已有主机复制」下拉
# 复制后 name 自动加 "-副本"，凭据字段引用同一私钥路径（口令/密码一并复制）
          startup_commands = ["cd /opt/deploy", "ll"]
```

---

## 14. macOS 平台集成
IME `NSTextInputClient` 候选框光标锚定；OSC 52 双向剪贴板（远端写入前过滤控制字符+轻提示）；多行粘贴注入防护（bracketed paste 不可用时弹确认）。

---

## 15. 项目工程结构（Zig 0.17.0）
```
src/
├── app/      (app_context, session_manager, host_store, keybinds, group, reconnect)
├── ui/       (window_frame, merged_tabbar, sidebar{展开/折叠}, split_pane, quick_connect,
│              command_palette, sftp_drawer, drag_hud, transfer_panel,
│              ai/{edge_strip, float_card, perm_switch, model_bar, remote_file_picker},
│              reconnect_banner, settings/*8页, terminal/{node,draw_pass,font_atlas,selection,gutter})
├── vt/       (vt_interface, ghostty_vt, vterm_c, cell, line, page_list, raw_tap)
├── ssh/      (worker, session, tunnel_supervisor, channel_stream, sftp_pipeline, sftp_dedicated)
├── proto/    (plugin_interface, ftp/, vnc/, kvm_redfish/)
├── ai/       (provider, agent_runtime, tools/{exec,read_screen,group,read_remote_file},
│              context_collector, permission_gate, redact)
├── builtin/  (at_commands{行首触发判定}, completion/{frecency,path_cache,static_table})
├── theme/    (plist_parser, sauber_theme, theme_manager, overlay_tokens)
└── platform/ (仅非 UI 系统能力；窗口、输入、Metal 生命周期由 Zenit 提供)
```

---

## 15b. 后续方向（设计保留 · 延后实现 · 非必须）

### 后续项处理总分析（FTP/VNC/RDP/KVM/Markdown 统一结论）

| 后续项 | 接入方式 | 复用 | 新增效果图 |
| :--- | :--- | :--- | :--- |
| FTP/FTPS | 实现 §7 契约的 TransferEngine（纯 Zig RFC 959 ~800 LOC） | 统一传输面板/管理器/设置-传输页 100% 复用 | 不需要（同传输体系） |
| VNC | 契约的 RenderNode 位图通路 + 键鼠映射 | 分栏/Tab/状态栏复用 | 接入时再出 |
| RDP | FreeRDP FFI 帧缓冲 → RenderNode | 同上 | 接入时再出 |
| KVM | V0.3：独立原生视频内容，Redfish 电源/启动气泡 | 标准公共槽位、SSH 配置与独立传输实现；不增加侧栏卡片 | V0.3§11 |
| Markdown 笔记 | Zenit 原生编辑/预览双栏 + 侧栏笔记分组 | 字体/文本布局模块复用 | 接入时再出 |

> 所有后续项均**不改主程序结构**（插件注册表登记即可）；本次交付不为它们产出效果图，避免范围混淆。

### 本地 Markdown 知识库
- **定位**：内置本地文档库（Markdown 为主，支持附加图片），运维笔记/故障复盘/命令速查随取随用
- **形态**：侧栏第四个分组「📒 笔记」；编辑器为 Zenit 原生 Markdown 编辑/预览双栏（复用字体渲染与文本布局模块，不引入 WebView）；图片存 `~/.zerowork/notes/assets/` 相对引用
- **与终端联动**：选中终端输出 → 中键菜单「存为笔记片段」；笔记中命令行可一键「在终端运行」
- **与 AI 联动（后期）**：笔记库作为 AI 附加上下文来源（本地 RAG：标题+段落索引，发送前预览脱敏）；AI 诊断结论可一键「存为复盘笔记」
- **边界**：纯本地文件，不进 git 不同步（首版）；后续可评估 iCloud Drive 目录映射
- 本条目仅保留设计，**当前版本不实现、无效果图**，路线图不占排期。

---

## 16. 路线图与验收指标

| 阶段 | 周期 | 核心任务 | 验收标志 |
| :--- | :--- | :--- | :--- |
| P0 骨架 | W1上 | build.zig + Zenit 版本钉住 + 窗口 + 配置/主题（AI 色板 token 预留） | 启动 <80ms |
| P1 VT+单跳SSH | W1下-W2 | VT 引擎 + feed 通路 + PTY + **★SessionContextProvider 接口落地** | vim/htop 完美渲染 |
| P2 渲染交互 | W3 | 三 pass 批次 + 选择复制 + gutter + **★OverlayHost 锚定框架** + 快捷键分层 | 效果图 diff ≤2px |
| P3 多跳+传输+SOCKS5 | W4-5 | ProxyJump + 认证框架五类 + SFTP 窗口引擎 + 独立连接 + **★ExecBridge** + SOCKS5 + 链路弹层 | 3跳正常；大文件传输击键 p95 <50ms |
| P4 组/广播/置顶 | W6 | @grp/@new/@dup/@pin/@sync + **★GroupContext** | 4 格同步 |
| P5 回溯/重连/墓碑态 | W6 并行 | RawStreamTap + @log 回放 + 重连状态机 + 墓碑态 | kill 对端 30s 内恢复 |
| P6 补全/快连/侧栏 | W7上 | frecency 补全 + ⌘K + 侧栏资产菜单 | 补全 <0.5ms/键 |
| P7 **AI 辅助（后期接入）** | W7下-W8 | 浮窗 + Provider + 权限管线 + 回合清理协议 + 组执行（**只消费 P1/P3/P4 已落地接口，不改 L0-L3**） | 中止后远端零残留进程 |
| P8 打磨发布 | W9 | 设置全量 + 三套菜单 + DMG+ad-hoc 打包 | 干净机器拖拽安装可用 |
| 后续（不在本次范围） | — | FTP/VNC/RDP/KVM/Markdown 按 §7 契约与 DESIGN 06 逐个接入 | — |

---

## 17. macOS 打包与分发方案（非上架 · 自用/内部分发）

### 17.1 构建与静态链接

```bash
zig build -Doptimize=ReleaseFast        # 目标 aarch64-macos (Apple Silicon 原生, 不出 universal)
zig build bundle                        # Info.plist 注入 + 图标 + ZeroWork.app 组装
```

- vendor 依赖（libssh2 / mbedtls / libghostty-vt）全部静态链入主二进制 → 无第三方 dylib，单二进制 8-15MB。

### 17.2 代码签名（定案：Ad-hoc 本地签名）

```bash
codesign --force --deep --sign - ZeroWork.app
codesign --verify --deep --strict ZeroWork.app
```

- 选定 Ad-hoc：自用分发，Gatekeeper 首次「右键 → 打开」；无开发者账号成本
- 备选（未来 MDM 批量分发）：Developer ID + 公证 或 pkg —— 非本次范围。

### 17.3 DMG 分发（定案）

```bash
hdiutil create -volname ZeroWork -srcfolder ZeroWork.app -ov -format UDZO ZeroWork-0.1.0-arm64.dmg
```

- 标准拖拽安装盘（/Applications 软链）；UDZO 压缩；arm64-only 命名明示。

### 17.4 首次运行与隐私明示

- README：首次「右键 → 打开」；配置明文（chmod 600）风险提示；数据仅存本地；无遥测无自动更新。

---

⌘F 打开当前会话搜索条，只搜滚动区文本，不搜时间戳 gutter。Enter 下一条，⇧Enter 上一条，Esc 关闭。

## 18. 可编辑效果稿入口

历史效果图和截图已清理。当前设计通过[设计中心](../UI_V3/index.html)、[状态索引](../UI_V3/SCREENS.md)及各模块 HTML/CSS/JS 查看；旧版本外观可查阅 [V2 HTML 原型](prototypes/v2/index-dark.html)。

---

## 12. 内置日志系统（补充设计需求）

### 12.1 目标

"能看到每次操作走到哪、断在哪、错在哪"——UI 点击、连接生命周期、worker I/O、AI 请求、配置读写全部有迹可循，排查问题不再依赖 stderr 临时探针。

### 12.2 落盘位置与文件

```
~/.zerowork/logs/app-<YYYYMMDD>-<HHMMSS>.log   # 每次启动一个新文件
~/.zerowork/logs/app-*.log.1                   # 轮转旧档（单文件写满时）
```

- 与会话数据（`logs/session.log`、`logs/session.checkpoint`，属 VT timeline）物理隔离
- 目录启动时自动创建；旧 `app-*.log` 按文件名日期清理（默认保留 7 天）。

### 12.3 行格式

```
HH:MM:SS.mmm +<运行时长>ms LEVEL module] 消息（fmt 参数展开）
```

- `LEVEL`：DEBUG / INFO / WARN / ERROR
- `module`：app / ui / workspace / ssh / vt / transfer / ai / config
- 单行 2048 字节上限，UTF-8。

### 12.4 级别与过滤

- 正式 App 使用内置默认日志级别（DEBUG 及以上），不接受环境变量运行时覆盖，也不为此新增设置入口；额外诊断仅供显式测试/自动化构建，不能通过正式 App 的环境变量开启
- WARN/ERROR 同时镜像到 stderr（终端运行立即可见）。

### 12.5 线程与性能

- 内部自旋锁（与 `Timeline` 同款 `atomic.Mutex`），UI 线程 / worker 线程共用一个 sink
- 单文件 `8MB` 上限，超出轮转为 `.1`
- 写入失败静默吞掉（日志永远不能拖垮业务）；`applog.init` 在 `main` 最前调用，任何模块失败自动降级为无文件输出。

### 12.6 埋点约定（各模块必埋）

| 阶段 | 必须记录 |
| :--- | :--- |
| 启动 | app 版本、日志文件路径、pid；workspace 加载的主机数与 hosts.toml 路径 |
| 连接 | openSession（host/user/port、双击/右键来源）→ 连接线程启动 → connect OK/FAILED（含错误名）→ outcome 消费（bind worker） |
| 会话 | selectTab / closeTab / 复用已有 tab |
| SSH | session init（auth 类型）→ 完成/失败；worker 线程启动 |
| 配置 | loadHosts 成功/失败与条目数 |
| 后续模块 | transfer 的队列/分片进度、AI 的回合开始/结束/错误，落地时同步埋点 |

### 12.7 实现锚点

- `src/platform/applog.zig`：`init(config, io)` / `debug|info|warn|err(module, fmt, args)`
- 入口：`src/main.zig` 的 `main` 首行。
