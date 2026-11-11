# UI_V4 · SVG 设计

当前三个设计稿使用独立的“晴霜”主题，配色取自最初参考图。

本目录保存当前可编辑 SVG 设计稿及其说明。

[V0.5 笔记插件](notes/README.md)：标准内容页与连接会话内2/3右侧浮窗、文档只读、块级实时编辑、搜索返回、保存／恢复错误及宽窄15张SVG；知识库下最多两级子目录，隐藏暂停、显示增量渲染。

| 当前设计稿 | 逻辑视口 |
| --- | --- |
| [主工作区](mist-workspace.svg) | 1440 × 900 |
| [窄窗口收起态](mist-workspace-compact.svg) | 860 × 480 |
| [窄窗口展开态](mist-workspace-compact-expanded.svg) | 860 × 480 |
| [主机分组侧栏](host-group-sidebar.svg) | 262 × 600 |
| [MCP 服务列表](mcp-services.svg) | 640 × 390 |
| [MCP 服务列表窄版](mcp-services-compact.svg) | 440 × 390 |
| [本地技能](skills.svg) | 640 × 390 |
| [本地技能窄版](skills-compact.svg) | 440 × 390 |
| [AI 本地工作区与文件变更](ai-project-workspace.svg) | 664 × 520 |
| [AI 本地工作区设置入口](ai-project-workspace-setup.svg) | 664 × 520 |
| [V0.6 网页连接与书签](web-connection.md) | 1440 × 900 |

[KVM 工具栏](kvm-toolbar-responsive.svg) 展示 520／336／240 点会话宽度：左侧显示图标和主机名，右侧显示连接状态及操作；不足 480 点时，五项操作和连接状态都转为纯图标，主机名按可用宽度省略；不足完整图标行所需的 264 点时，电源与启动才收进三点菜单。工具栏高 44、图标按钮 32、视频间距 16。原生实现同时验证 480／264 点切换边界和 228 点最小排列宽度。

MCP 服务列表的尺寸、状态和原生交互见 [MCP 服务规范](mcp-services.md)。
本地技能的导入区、列表和正文归属见 [本地技能规范](skills.md)。
本地目录入口、basename 与标准文件变更折叠卡片见 [AI 本地工作区增量设计](ai-project-workspace.md)。

设计前阅读 [设计要求](DESIGN_REQUIREMENTS.md) 和 [风格指南](STYLE_GUIDE.md)。精确布局与行为约束见 [主界面规范](mist-design.md)。

**本目录只允许 `.svg` 和 `.md` 文件。禁止存放 PNG、JPG、WebP、GIF 等图片，也不存放截图、预览、验证报告、日志、JSON 或脚本。** SVG 必须是可编辑设计稿，不用 SVG 外壳包装截图。

生成器与验证器位于 `tools/ui_v4/`；本地导出、截图、测量和机器报告统一写入仓库外部的临时目录，或仓库根目录已忽略的 `artifacts/ui-v4/`。运行：

```sh
python3 tools/ui_v4/generate_mist.py
python3 tools/ui_v4/verify_mist.py
```

本目录仅保留最新设计，不存放历史方案和逐次修订记录。
