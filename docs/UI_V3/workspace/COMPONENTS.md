# 工作区功能组件契约

本目录以同一个`app.js`模型和控制器提供模块页、独立功能组件和整机预览。`?component=<id>`只裁切与打开当前功能的必要状态，**不生成第二份组件markup或业务模型**。通用外壳通过`V3.tab`与`shared/functional.css`复用；未来Zenit映射沿用WorkspaceModel/SessionHandle，不把HTML iframe带入原生实现。

| 功能组件 id | 来源 renderer/controller | 核心选择器 | 可操作状态/参数 |
| --- | --- | --- | --- |
| shell-tabs | renderTabs → V3.tab | #tabs, .titlebar | 点击/右键/关闭/拖序；mode=local/ssh/group；theme |
| host-sidebar | renderHosts, showHostMenu, showWorkspaceTooltip | #sidebar, #tooltip, #context-menu | sidebar=expanded/collapsed；搜索/折叠/右键/连接；隔离页只有原侧栏折叠按钮，整机只显示顶栏折叠钮 |
| terminal-input | terminalPane, inputCommand, commandKey | .terminal-scroll, .command-input, .command-palette | mode=local/ssh；直接输入、@补全、参数、右键粘贴与中键菜单 |
| command-record | logMarkup, appRecord, execute | .app-command, .command-input | mode=ssh；@ts/@help/未知命令可生成成功或失败记录；与Shell文档同起点 |
| session-menus | showHostMenu, showTabMenu, showTerminalMenu, menu | #context-menu | menu=host/tab/terminal；mode=local/ssh；真实复制配置、新会话、搜索、历史与导出入口；禁用能力保留状态 |
| connection-status | renderStatus, identityPopover | #statusbar, #popover | mode=ssh/local；state=failed；延迟与状态同一组件 |
| connection-route | connectionNodes, chainPopover, testConnectionRoute | #popover, #modal-root | mode=ssh；state=failed；查看节点、编辑、测试、取消；测试冻结原路径与owner |
| broadcast | broadcastPopover | #popover | mode=group打开组；未入组有创建入口；source/receiver确认与禁用状态 |
| port-forward | forwardPopover, forwardList, socksError | #popover, #modal-root | mode=ssh/local；添加/暂停/删除/冲突，非SSH有能力说明 |
| transfer | transferPopover, transfersDialog, queueJob | #popover, #modal-root | 摘要→真实任务管理器→任务操作；来源模型与全局投影共享 |
| ai | renderAssistant, positionAssistant, aiData | #assistant, #ai-edge | 拖动、三窗控、历史/新对话、模型/权限/附件/用量、提问/批准/停止；mode=ssh/local/ai-error/ai-unconfigured |

公共参数：`theme`沿用十二主题；`mode`沿用模块真实场景。`component`页面居中渲染有界画布，无外部评审工具；浮卡仍依真实触发点定位。`document.documentElement.dataset.componentReady`标记初始场景建立，不等价业务异步完成。root功能目录可以在外部提供状态选择器，通过query重载同一来源。

菜单先对照实际`src/ui/context_menus.zig`，鼠标语义对照`terminal_surface_input.zig`。HTML只支持浏览器文本选择，原生矩形块选用⌥拖拽；该菜单项明确解释差异。新窗口能力沿原生当前门控禁用，不以当前tab打开冒充新窗口。剪贴板是浏览器权限能力，拒绝时保留输入并明确给出⌘V替代。AI工具与传输仍使用当前原型模拟，不连接真实主机。
