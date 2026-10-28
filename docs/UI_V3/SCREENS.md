# V3 功能页与状态效果图

## 0.2.6 AI 执行与会话管理 PATCH（设计稿）

[可编辑交互入口](ai-session-execution/index.html) · [状态索引](ai-session-execution/README.md) · [详细设计](../DESIGN/V0.2.6_AI_SESSION_EXECUTION.md)。覆盖全局设置与 composer 模式、批处理/交互式命令卡、单会话建组后的真实工具步骤、PTY 控制权、清理及只读历史。效果稿使用本地确定性数据，非真实 SSH/模型执行；原生验收状态以详细设计中的门槛为准。

本项状态入口与历史验证记录见[专项记录](ai-session-execution/verification/README.md)：[全局设置](ai-session-execution/index.html?state=settings)、[composer 模式](ai-session-execution/index.html?state=mode-menu)、[批处理结果](ai-session-execution/index.html?state=exec)、[PTY 工作流](ai-session-execution/index.html?state=pty-running)、[PTY 输出](ai-session-execution/index.html?state=pty-running)、[关闭后历史](ai-session-execution/index.html?state=history)、[紧凑审批](ai-session-execution/index.html?state=ask&viewport=compact)。

当前分层与范围以[组件组合合同](COMPONENT_MAP.md)及[本轮一致性检查](verification/consistency.md)为准：通用组件→功能组件→功能模块→整机；VNC/RDP/FTP独立归未来设计，默认预览保留KVM。

本轮逐项检查：[交互与布局审计](AUDIT.md) · [Zenit落地条件](ZENIT_READINESS.md)。历史记录以本轮实际测量与分模块报告为准。

[设计中心](index.html) · [完整功能与组件验收表](COVERAGE.md)。以下都是可编辑HTML原型的实际浏览器状态；完整交互以模块入口及README为准。所有网络、模型和系统能力为本地模拟，未来协议不等于当前App已经支持。连接和设置完整模块按用户确认冻结，其余调整见本轮验收与冻结边界。

## 工作区与 AI

| 功能页 / 状态 | 可点击入口 | 原型 / 契约 |
| --- | --- | --- |
| 本地 ZSH | [默认窗口](workspace/index.html?mode=local) | [工作区说明](workspace/README.md) |
| SSH 与会话组 | [SSH](workspace/index.html?mode=ssh)、[组](workspace/index.html?mode=group) | [命令流](workspace/index.html?mode=group) |
| SFTP 文件双栏 | [文件页](workspace/index.html?mode=sftp) | [双卡片深色](workspace/index.html?mode=sftp&size=compact) · [浅色](workspace/index.html?mode=sftp&size=compact&theme=light) |
| 完整底栏浮卡 | 各工作区底栏的连接状态、广播、链路、转发、文件传输 | [交互契约](workspace/README.md) |
| AI 顶部浮窗 | [AI](workspace/index.html?mode=ai)、顶部三点 / ⌘J / @ai | [浮窗效果](workspace/index.html?mode=ai) |
| 最小窗口 | [860×480](workspace/index.html?mode=local&size=compact) | 不缩放字体，保留显式工具入口 |
| 只读历史 | [历史回放](workspace/index.html?mode=history) | 独立页签、时间轴与返回实时 |

## 连接、未来协议与笔记

| 功能页 | 可点击入口 | 重点 |
| --- | --- | --- |
| 新建连接 | [三步向导](connection/index.html) | 协议/身份认证/高级、多跳、测试、仅保存/保存连接 |
| 资产管理 | [连接管理](connection/index.html?open=none) | 搜索、分组、主机操作、快捷连接 |
| BMC iKVM | [在线](kvm/index.html?protocol=kvm) | 控制权/按键/显示/电源/启动、异常、共享AI |
| VNC | [远程桌面](kvm/index.html?protocol=vnc) | 图像、只读与控制、显示、重连 |
| RDP | [远程桌面](kvm/index.html?protocol=rdp) | 身份/证书/显示、输入与断线 |
| FTP / FTPS | [文件工作区](kvm/index.html?protocol=ftp) | TLS/主动被动/目录/传输 · [双卡片](kvm/index.html?protocol=ftp) |
| Markdown 笔记 | [双栏工作区](notes/index.html) | [双栏卡片](notes/index.html)、[上下文预览](notes/index.html)、[最小窗口](notes/index.html) |

连接与未来协议的完整状态图及交互说明见 [连接README](connection/README.md)、[KVM README](kvm/README.md)。历史连接原文件未找回，本次为重新补全的新交互稿，门户不再把恢复登记作为连接弹窗。

## 设置与公共组件

| 功能页 / 状态 | 可点击入口 | 原型 / 契约 |
| --- | --- | --- |
| 设置总览 | [外观](settings/index.html?page=appearance) | [总览](settings/index.html) |
| 主题库 | 外观 → 主题卡片 | [主题](settings/index.html) |
| 字体与光标 | [字体场景](settings/index.html?state=font) | [状态图](settings/index.html?state=font) |
| Provider空态 | [AI设置](settings/index.html?page=ai) | [空态](settings/index.html?page=ai) |
| Provider与模型 | [配置示例](settings/index.html?state=ai-populated) | [单行模型](settings/index.html?state=ai-populated) |
| 模型能力与测试 | 获取模型清单 → 添加模型 → 测试，失败点状态查看详情 | [交互契约](settings/README.md) |
| 其他设置分类 | 快捷键、SSH与网络、文件传输、协议插件、通知、数据日志 | [完整设置映射](settings/README.md#完整功能对照与原生映射2026-10-25-补全) |
| 公共组件 | [独立展板](components/index.html) | [组件契约](components/README.md) |

## 对照资料

[本轮Figma参数](verification/figma-reference.json)。原生参考截图已清理；现有原型用于查看设计，原生实现状态仍以交接合同为准。

## 专项状态与独立参考

以下均为 HTML/CSS/JS。标为“排版 / 状态参考”的页面保留尺寸示例，并提供进入真实交互原型的链接；不将参考页中的静态按钮当作已接通的功能。

| 页面 | 入口 | 交互来源 |
| --- | --- | --- |
| AI 执行与审批 | [专项原型](ai-session-execution/index.html) | 页面场景选择与完整执行卡 |
| 历史会话 | [列表](workspace/session-history/index.html?state=list)、[回看](workspace/session-history/index.html?state=tab)、[页签菜单](workspace/session-history/index.html?state=menu)、[@log](workspace/session-history/index.html?state=log) | 复用工作区历史 renderer |
| 连接进度 | [直连](connection/progress.html)、[多跳](connection/progress.html?route=3)、[失败](connection/progress.html?route=3&state=failed) | 日志、取消、重试与关闭 |
| 全局通知 | [消息](notifications/index.html)、[历史](notifications/history.html) | 查看操作进入对应会话 / 传输 / AI 原型 |
| AI 区域参考 | [初始区域](ai/welcome.html)、[回合与步骤](ai/conversation.html) | [工作区 AI](workspace/index.html?mode=ai) |
| 设置排版参考 | [模型行](settings/model-row.html)、[模型编辑器](settings/model-editor.html)、[信息层级](settings/settings-hierarchy.html) | [模型组件](settings/index.html?component=model-row)、[完整设置](settings/index.html) |
| 状态弹层参考 | [连接状态](workspace/status-popovers/index.html)、[会话状态提示](workspace/session-notice/index.html)、[端口转发](workspace/forwarding/index.html) | [工作区](workspace/index.html?mode=ssh)、[转发组件](workspace/index.html?mode=ssh&component=port-forward) |
