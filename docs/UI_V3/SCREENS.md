# V3 功能页与状态效果图

当前分层与范围以[组件组合合同](COMPONENT_MAP.md)及[本轮一致性检查](verification/consistency.md)为准：通用组件→功能组件→功能模块→整机；VNC/RDP/FTP独立归未来设计，默认预览保留KVM。

本轮逐项检查：[交互与布局审计](AUDIT.md) · [Zenit落地条件](ZENIT_READINESS.md)。历史记录以本轮实际测量与分模块报告为准。

[设计中心](index.html) · [完整功能与组件验收表](COVERAGE.md)。以下都是可编辑HTML原型的实际浏览器状态；完整交互以模块入口及README为准。所有网络、模型和系统能力为本地模拟，未来协议不等于当前App已经支持。连接和设置完整模块按用户确认冻结，其余调整见本轮验收与冻结边界。

## 工作区与 AI

| 功能页 / 状态 | 可点击入口 | 图片 / 契约 |
| --- | --- | --- |
| 本地 ZSH | [默认窗口](workspace/index.html?mode=local) | [工作区说明](workspace/README.md) |
| SSH 与会话组 | [SSH](workspace/index.html?mode=ssh)、[组](workspace/index.html?mode=group) | [命令流](workspace/verification/ssh-group-commands.png) |
| SFTP 文件双栏 | [文件页](workspace/index.html?mode=sftp) | [双卡片深色](verification/card-separation/sftp-compact.png) · [浅色](verification/card-separation/sftp-light-compact.png) |
| 完整底栏浮卡 | 各工作区底栏的连接状态、广播、链路、转发、文件传输 | [交互契约](workspace/README.md) |
| AI 顶部浮窗 | [AI](workspace/index.html?mode=ai)、顶部三点 / ⌘J / @ai | [浮窗效果](verification/ai-float-final.png) |
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
| FTP / FTPS | [文件工作区](kvm/index.html?protocol=ftp) | TLS/主动被动/目录/传输 · [双卡片](verification/card-separation/ftp-compact.png) |
| Markdown 笔记 | [双栏工作区](notes/index.html) | [双栏卡片](verification/card-separation/notes-compact.png)、[上下文预览](notes/verification/notes-context-preview.png)、[最小窗口](notes/verification/notes-compact.png) |

连接与未来协议的完整状态图及交互说明见 [连接README](connection/README.md)、[KVM README](kvm/README.md)。历史连接原文件未找回，本次为重新补全的新交互稿，门户不再把恢复登记作为连接弹窗。

## 设置与公共组件

| 功能页 / 状态 | 可点击入口 | 图片 / 契约 |
| --- | --- | --- |
| 设置总览 | [外观](settings/index.html?page=appearance) | [总览](verification/settings-overview.png) |
| 主题库 | 外观 → 主题卡片 | [主题](verification/themes-inline.png) |
| 字体与光标 | [字体场景](settings/index.html?state=font) | [状态图](verification/font-cursor.png) |
| Provider空态 | [AI设置](settings/index.html?page=ai) | [空态](verification/providers-empty.png) |
| Provider与模型 | [配置示例](settings/index.html?state=ai-populated) | [单行模型](verification/models-one-line-final.png) |
| 模型能力与测试 | 获取模型清单 → 添加模型 → 测试，失败点状态查看详情 | [交互契约](settings/README.md) |
| 其他设置分类 | 快捷键、SSH与网络、文件传输、协议插件、通知、数据日志 | [完整设置映射](settings/README.md#完整功能对照与原生映射2026-10-25-补全) |
| 公共组件 | [独立展板](components/index.html) | [组件契约](components/README.md) |

## 对照资料

[本轮Figma参数](verification/figma-reference.json) · [原生AI参考](verification/reference/native-ai-unconfigured.png) · [原生连接向导参考](verification/reference/native-connection.png)。原生参考用于判断现有交互及布局，不把App尚未完整V3的外观反过来覆盖本次V3稿。
