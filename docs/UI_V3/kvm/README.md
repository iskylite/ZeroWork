# 图形、KVM 与后续协议 · V3 交互稿

> 当前评审： [2026-10-26 修订说明](../REVIEW_20261026.md) · [效果图总览](../review-20261026.html)。本轮替代下文与其冲突的侧栏、会话、气泡、连接页与 KVM 展示规则；待用户确认后再落地 APP UI。
[规划 KVM](index.html) · [KVM AI](index.html?state=ai) · [连接失败](index.html?state=failed) · [VNC](index.html?protocol=vnc) · [RDP](index.html?protocol=rdp) · [FTP / FTPS](index.html?protocol=ftp)

这是同一套公共 App 壳中的后续协议 HTML 设计。保留顶栏/侧栏/底栏/公共 AI 浮窗，协议只贡献内容页与相应功能。所有数据为本地模拟，不能视为这些协议已在当前 APP 实现。

## 已覆盖的功能与状态

| 区域 | 功能 / 状态 | 可点击路径 |
| --- | --- | --- |
| 公共壳 | 标准1440×900、最小860×480、侧栏展开/折叠、搜索、主题、全局传输任务、AI三点边条 | 顶部评审尺寸/主题，侧栏箭头，底栏，右上工具 |
| KVM 内容 | 主机→KVM tag→状态同一行；44px透明工具栏；下方视频不套重复卡片 | 在线场景 |
| 控制权 | 只读、申请、等待/批准/拒绝、释放；人工与AI互斥；画面捕获/Esc释放 | 控制菜单→申请→演示批准/拒绝 |
| 按键 | Ctrl+Alt+Del、Ctrl+Alt+F1/F2、F1–F12、Esc、Super、Alt+Tab；只读禁用 | 按键菜单 |
| 显示 | 适应窗口、100%原始比例滚动、全屏预览/还原 | 显示菜单 |
| 电源 | 当前状态、开机/正常关机/重启/强制断电、明确目标/风险、普通操作直接执行、强制断电风险确认、结果待确认不重发 | 电源菜单→执行 |
| 启动 | Disabled/PXE/HDD/USB/CD/BIOS；Once/Continuous、UEFI/Legacy独立草稿；跨菜单/关闭重开保留；执行读回后无更改禁用 | 启动菜单 |
| 启动顺序 | 只读BootOrder，不能拖动或写入 | 启动→查看启动顺序 |
| 连接 | 原路径进度、目标/路由保留失败、重试、取消、无信号但管理在线、日志、关闭 | 场景选择连接中/失败/无信号，底栏连接详情/链路 |
| AI总体 | 共享600×456浮窗，单行header含只读owner；三点边条/新建/历史/收起/最大化还原/关闭/拖动/缩放；附件/权限/模型/用量固定输入区 | 右上AI或上方三点边条 |
| AI观察 | 明确Provider发送授权、图像预览、模型不支持图像、旧观察失效 | 观察当前画面→允许；模型按钮；控制中→演示观察过期 |
| AI输入 | 独立10分钟/32步租约；鼠标移动/单击/双击/右键/拖拽/滚轮/组合键/文本步骤；停止/人工接管清旧队列 | 授权本次任务→执行一步并重新观察→停止 |
| AI危险动作 | 电源/启动差异待批、拒绝/过期零派发、AUTHKEY二次认证、accepted→verifying→succeeded、unknown仅查询 | 规划重启/一次性PXE→审批→认证→继续验证/响应丢失 |
| VNC / RDP | 各自桌面夹具、输入控制权、组合键、比例/全屏、剪贴板显式文本发送，不自动同步系统剪贴板 | 协议选择VNC/RDP |
| FTP / FTPS | 双栏独立路径/上级/目录缓存、选择/多选、刷新、预览、新建文件夹、重命名、删除确认 | 协议选择FTP / FTPS |
| FTP传输 | 上传/下载确认、批量名称、冲突跳过/保留两者/重命名/覆盖（二次风险确认）、锚定全局任务气泡/筛选/暂停/恢复/失败/重试/取消；切换协议仍保留任务 | 选文件→上传/下载→演示冲突；传输管理器 |
| FTP AI | 当前目录摘要、只读上下文、创建归档文件夹计划与明确审批；不向FTP开放BMC电源/启动工具 | FTP→AI→规划归档文件夹 |

## 参考与限制

- 核心参考 `docs/DESIGN/V0.3_BMC_IKVM.md` §3、§8、§9、§11；后续AI参考 `docs/DESIGN/V0.2.3_KVM_AI_CONTROL.md`。Figma线上节点本任务实际读取 `1066:217241`（启动/Dark）；根任务统存 `../verification/figma-reference.json` 其他节点证据。
- KVM工具栏五组透明入口：控制、按键、显示、电源、启动；电源296px、启动312px气泡、padding12/gap12/radius12，输入32px/radius8；所有浮层锚点相对APP计算并clamp，底栏气泡向上展开。
- 沿用现有V3 tokens、17px/1.7线性SVG、系统中文字体；已统一常驻图标为SVG。没有使用截图代替交互。
- AI标准窗600×456，最小窗600×354；默认相对当前内容区居中定位并约束在APP内8px，随侧栏与窗口变化重算。固定审批152px，固定输入90px，历史区受控滚动；头部与owner沿公共工作区结构，不另设右侧栏。
- KVM不展示终端广播、用户转发或当前会话传输摘要；全局传输按钮保留其他会话任务。
- 不包括虚拟媒体、ISO上传、录像、SOL、传感器、BMC用户/固件管理、BootOrder写入；这是已有设计明确排除的功能，不能靠“全量”误加。
- 视频是可编辑HTML夹具，未连接BMC/VNC/RDP，不代表像素协议、BIOS输入或电源实机验证。AI图像/租约/坐标与审批均为可点击状态，未发送Provider或远端动作。真实协议能力、TLS/主机信任、密钥存储、权限与原生帧缓冲仍需后续实现和实机验收。

## 原生组件映射

公共壳映射到现有Workspace/Sidebar/Tabbar/StatusBar；浮层复用 `ui.widgets.Popover/Tooltip/Modal/Select/Switch/Button/ScrollArea`；主机像素区映射 `FrameTextureSink` 原生纹理而不是WebView；输入事件走绑定会话/代际的 RemoteInputService；Power/Boot 走同会话管理operation；AI使用共享助手、ToolResult、ApprovalCard、Challenge与NotificationHost。实际框架API以项目vendor/zenit和Zig0.17为准，不照技能示例降级工具链。

## 已做定向验证

浏览器100%缩放、DPR2：KVM启动PXE+Continuous+Legacy独立选择→执行→关闭重开读回，执行无更改禁用；强制断电保留二次风险确认；左下连接详情296px浮层全在App内；AI观察授权→预览→危险审批→AUTHKEY→accepted→unknown仅查询→verifying→succeeded；最小窗口浮窗和152px审批区域均在App内。VNC申请控制→授权→显式发送文本；RDP主题；FTPS选文件→冲突→保留两者→任务。主线程另做全量验收和覆盖表更新。

截图在 `verification/`，包含在线、启动、电源确认、AI审批/unknown/小窗、VNC、RDP、FTPS冲突与任务。交互稿语法通过 `node --check`。浏览器夹具不能代替原生功能验收；所有新稿待用户确认，本任务不修改原生程序，不提交Git。

### 最终共享控件验收补充

最终资源版本为 `20261025-audit-12`。已实际点击336px模型选择器、effort中→高（独立审计）、确认后执行/完全控制和用量分解；草稿在模型/权限/最大化/还原/收起重开后保留，新建对话转移至历史，恢复后旧观察失效而原草稿保留。历史包含用户消息、回复快照和草稿；不恢复旧输入租约或旧批准。最小窗最终为600×354，审批152px、输入90px、历史阅读区64px（大于要求的52px），全在App内。相关紧凑、审批和未知状态通过[可交互 HTML 原型](index.html?protocol=kvm)查看，保留单行owner头及SVG控件。

本轮逐项操作、尺寸与原生映射以 [独立审计](../verification/connection-protocols-audit.md) 为准。公共主题最后加载 ../theme-tokens.css；标题栏46、状态栏32、区域间距6、侧栏224⇄48。全局传输管理器使用锚定 Popover（最大760px、受控滚动），关闭不取消任务。评审故障注入在 APP 外；产品 Select 使用 APP 内列表。

## 当前与未来设计隔离、功能组件故事

KVM保留当前完整设计规划；默认仅KVM。VNC/RDP/FTP通过`?future=1&protocol=vnc|rdp|ftp`进入未来设计，与当前整机预览隔离。

`feature=kvm-control|kvm-keys|kvm-display|kvm-power|kvm-boot|kvm-route|kvm-ai`进入同一模块controller的精确组件状态，供功能组件页复用，不复制独立版本。页签使用统一V3.tab，单pane不再额外显示连接身份/操作横幅。

本轮修改、实际关闭流程与尺寸见[一致性检查](verification/consistency/README.md)。
