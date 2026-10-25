# 本地笔记与知识库 · V3

[打开交互稿](index.html) · [返回设计中心](../index.html)。依据 `docs/SPEC/OVERALL_ARCHITECTURE.md` 的未来本地 Markdown 知识库方向新增；不是当前 App 已实现声明。视觉复用 V3 工作区 tokens、1440×900 逻辑窗口、224px侧栏、14px浮窗。

## 功能与状态

| 功能区 | 入口与行为 | 状态 / 原生映射 |
| --- | --- | --- |
| 列表与分组 | 搜索标题/正文；分组展开折叠、新建、改名、删除后保留笔记到未分组 | 空/无匹配/选中；VirtualList、Input、Accordion、Popover |
| 笔记管理 | 新建、标题改名、更多菜单复制/移动/删除确认 | 删除末笔记显示可恢复空态；Modal、Input、Menu |
| 编辑与预览 | Markdown 双栏、仅编辑、仅预览；编辑同步更新字符数和预览 | 未保存→模拟保存、失败保留草稿→重试；项目 pane_manager + Box、Textarea、Markdown |
| 图片 | 工具栏插入本地图片 → 示例预览/说明 → 相对资源路径插入编辑器 | 原生 FileDialog 与资源复制；原型只插入同目录SVG样例 |
| 导入/导出 | 粘贴 Markdown 导入；导出前完整内容预览 | 取消不改变列表；原生接入 FileDialog，原型不读写文件 |
| 终端联动 | 从首个命令块准备命令→确认→工作区输入草稿 | URL `workspace/?mode=local&noteCommand=...`，不自动执行 |
| AI 联动 | 附加上下文→可编辑预览/脱敏→确认→AI 草稿 | URL `workspace/?mode=local&ai=1&noteContext=...`，不自动发送 |
| 片段收集 | `?title=...&fragment=...` | 工作区终端片段/AI复盘进入新笔记草稿，不覆盖原笔记 |
| 通用窗口 | 明确侧栏折叠、三主题、设置/终端/新连接入口 | 弹窗位于 APP 内，Esc/取消关闭 |

## 实测记录

2026-10-25，Codex IAB，1280×720 CSS px、DPR2、100%缩放，页面滚动呈现1440×900窗口。

- 点击新建笔记并输入Markdown，预览与字符计数更新。
- 创建“发布”分组→管理分组→改名“发布清单”，列表显示新名及0项空态。
- 模拟保存失败后草稿保留；修正了延迟保存回调错误覆盖失败提示的问题。
- AI上下文预览框包含完整内容；测量dialog完全处于APP矩形之内。
- 截图：[双栏](verification/notes-split.png)、[上下文预览](verification/notes-context-preview.png)。
- `node --check app.js` 通过。跨工作区联动由根验收记录补充。

## 边界

全部数据在页面内存中，刷新/重置恢复示例；不持久化真实文件。Markdown渲染演示标题和代码块，原生实现使用既有Markdown组件支持完整语法，不能直接采用此简化预览替代。原型不执行命令、不调用模型，不模拟真实权限已授予；系统文件选择、文件冲突、真实图片资源复制与本地检索索引仍须原生后端接入。设计不包含云同步。

补充验收：实际点击笔记→准备两行命令→工作区textarea，换行完整保留；Enter显示逐行发送确认，取消返回草稿。最小窗口切换实测860×480，截图见verification/notes-compact.png。

图片插入已实际点击：示例预览→插入→编辑器出现相对路径，右侧出现图片；截图 [图片状态](verification/notes-image.png)。弹窗支持Tab范围约束与关闭回焦，图标tooltip按APP矩形夹取。

最后跨模块复验：笔记→AI附加上下文→确认后，工作区AI问题框为空，附有“笔记上下文”；点击该附件显示真实141字符笔记原文、来源“笔记工作台”、保留换行，预算按实际文本估算，不再显示通用日志。证据：[工作区附件预览](verification/notes-workspace-attachment.png)。
