# UI_V4 · SVG 设计

本目录保存当前可编辑 SVG 设计稿、规范与说明。除连接向导稿沿用当时的深色绿主题外，其余界面稿使用“晴霜”主题，逻辑单位均为点。

## 目录

| 目录 | 内容 |
| --- | --- |
| [standards](standards/) | 设计要求、风格指南、遮罩范围审查 |
| [workspace](workspace/) | 主工作区、窄窗、侧栏与主界面规范 |
| [connection-wizard](connection-wizard/) | SSH 连接向导的路由、身份、核对与保存错误 |
| [web-connection](web-connection/) | V0.6 网页连接、书签与地址栏 |
| [ai](ai/) | MCP 服务、本地技能、AI 本地工作区 |
| [notes](notes/) | V0.5 笔记插件 |
| [kvm](kvm/) | KVM 工具栏响应式布局 |
| [notifications](notifications/) | 通知关闭倒计时 |

## 规范

- [SVG 设计要求](standards/DESIGN_REQUIREMENTS.md)
- [SVG 主界面风格指南](standards/STYLE_GUIDE.md)
- [遮罩范围审查](standards/overlay-scope-audit.md)

## 主工作区

| 设计稿 | 逻辑视口 |
| --- | --- |
| [主工作区](workspace/mist-workspace.svg) | 1440 × 900 |
| [窄窗口收起态](workspace/mist-workspace-compact.svg) | 860 × 480 |
| [窄窗口展开态](workspace/mist-workspace-compact-expanded.svg) | 860 × 480 |
| [主机分组侧栏](workspace/host-group-sidebar.svg) | 262 × 600 |
| [主界面规范](workspace/mist-design.md) | — |

## 连接向导

[SSH 连接向导说明](connection-wizard/README.md)：9 张 SVG 覆盖连接与认证、连接路径、核对与测试及保存错误。

## 网页连接

[V0.6 网页连接与书签](web-connection/web-connection.md)：地址栏、书签、网页会话与窄窗规则。

## AI 辅助

| 设计稿 | 说明 |
| --- | --- |
| [MCP 服务规范](ai/mcp-services.md) | [列表](ai/mcp-services.svg) 640 × 390、[窄版](ai/mcp-services-compact.svg) 440 × 390 |
| [本地技能规范](ai/skills.md) | [列表](ai/skills.svg) 640 × 390、[窄版](ai/skills-compact.svg) 440 × 390 |
| [AI 本地工作区与文件变更](ai/ai-project-workspace.md) | [设计](ai/ai-project-workspace.svg) 664 × 520、[设置入口](ai/ai-project-workspace-setup.svg) 664 × 520 |

## 笔记

[V0.5 笔记插件](notes/README.md)：标准内容页与连接会话内 2/3 右侧浮窗、文档只读、块级实时编辑、搜索返回、保存／恢复错误及宽窄 15 张 SVG；知识库下最多两级子目录，隐藏暂停、显示增量渲染。

## KVM

[KVM 工具栏](kvm/kvm-toolbar-responsive.svg) 展示 520／336／240 点会话宽度：左侧显示图标和主机名，右侧显示连接状态及操作；不足 480 点时，五项操作和连接状态都转为纯图标，主机名按可用宽度省略；不足完整图标行所需的 264 点时，电源与启动才收进三点菜单。工具栏高 44、图标按钮 32、视频间距 16。原生实现同时验证 480／264 点切换边界和 228 点最小排列宽度。

## 通知

[通知关闭时间](notifications/command-error-countdown.md)：命令执行失败与全局通知的关闭倒计时、悬停暂停及历史保留。

## 约束与工具

**本目录只允许 `.svg` 和 `.md` 文件。禁止存放 PNG、JPG、WebP、GIF 等图片，也不存放截图、预览、验证报告、日志、JSON 或脚本。** SVG 必须是可编辑设计稿，不用 SVG 外壳包装截图。

生成器与验证器位于 `tools/ui_v4/`；本地导出、截图、测量和机器报告统一写入仓库外部的临时目录，或仓库根目录已忽略的 `artifacts/ui-v4/`。运行：

```sh
python3 tools/ui_v4/generate_mist.py
python3 tools/ui_v4/verify_mist.py
```

本目录仅保留最新设计，不存放历史方案和逐次修订记录。
