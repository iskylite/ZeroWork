# Composer 原位交互 HTML 基准

入口：[三状态预览](composer-interactions.html)；[完整工作区](../workspace/index.html?mode=ai&composer-interaction=approval)。

## 范围

只新增命令审批、选择问答、稍后处理入口。工作区标题栏、消息、步骤、原 composer、附件和原工具栏由既有渲染器提供。HTML 原型复用现有主题变量；原生落地范围见下方。

预览通过 `composer-interaction=approval|question|pending` 显式启用，`baseline` 使用同一内容但不挂载交互。无该参数的现有页面保持原行为。

展示页直接内嵌三张由原组件渲染的效果图，页面打开即可显示；交互层采用项目已有的 `V3DocumentHost` 同源 object 文档宿主，避免 iframe 在内置浏览器中的加载兼容问题。交互层载入并核对目标状态后才接管图片，失败时保留效果图并显示重试状态。窄窗口只缩放外部评审画布，不修改助手内部尺寸或字体。

## 交互约定

- 审批和问答在同一 composer 中替换输入内容，普通输入、附件与原工具按钮保持挂载。
- 稍后处理不批准、不拒绝、不提交空答案；恢复原草稿及控件。重新打开保留未提交选择和自定义答案。
- 提交在当前请求内只接受一次；停止仍由原 composer 主按钮与原停止流程处理。
- 待处理入口锚定 composer 右上方，26px 高、8px 间距，仅胶囊接收点击。无新增布局行；Transcript 增加 32px 底部滚动留白。
- HTML 仅模拟请求响应，不执行命令。

## 样式来源

继续使用 `shared/ai-assistant.js`、`shared/ai-assistant.css`、工作区样式与主题 token。新增样式限定在 `data-interaction-state` 与 `v3-ai-interaction-*` 下，不覆盖原标题栏、消息、步骤或普通工具按钮。

默认助手 600×456 CSS px、100% 缩放、DPR 1；原 composer 90px，工具按钮 24px，原主按钮 28px。交互内容替换 textarea 占用空间，操作栏保持原底部位置。普通状态带附件时继续由原组件决定高度。

## 本次验证

浏览器检查通过 20 项：无交互参数时，助手 DOM、计算样式与 600×456 截图均与去除新增资源引用的基线一致，截图逐像素相同。交互覆盖审批与拒绝、选项和自定义答案暂存、空答案校验、草稿与附件恢复、原停止流程、历史阅读位置及 360×358 紧凑尺寸。

实际测量：审批 composer 高 176px，问答高 224px，普通 composer 高 90px；三种状态的原工具栏均位于助手内 y=422，主按钮均为 x=558、y=422、28×28。原生实现与系统输入法未在此 HTML 任务中验证。

## 原生落地

原生主入口使用 `src/ui/ai_composer_interaction_view.zig` 和独立样式文件，复用 zenit 的 Button、RadioGroup、Input、ScrollArea。审批继续经过原来的命令、宿主授权校验；问答通过 `host.request_user_input` 的回合级 mailbox 等待明确答案。没有 WebView，也没有新增停止任务行。

普通 Textarea、附件与工具栏保持挂载；展开请求时只切换内容与操作槽，原发送/停止位置保持不变。稍后处理不返回工具结果，重新打开保留选择、自定义答案与普通草稿。切换显示会话只隐藏请求，停止/关闭任务取消等待，旧请求或按下途中的旧按钮不能确认新请求。

原生默认尺寸仍为 600×456；审批、问答、普通 composer 分别为 176、224、90px，操作按钮 24px，原停止按钮 28px。运行方式选择只在宿主要求选择时显示，其审批面板增加 32px。长请求在内容区滚动，决策按钮保持在外部。待处理胶囊 26px 高，位于 composer 右上方 8px，transcript 增加 32px 底部滚动留白。

验证包括原生组件的请求替换、防重复提交、选择及草稿暂存、空答案、长内容与紧凑布局，以及隔离完整 App 的真实问答、批准执行一次、拒绝零执行和原停止流程。隔离验收命令只在临时本地数据目录执行。物理中文输入法与 VoiceOver 尚未做人工验证。

复现：`zig build composer-interaction-preview -Dtest-mode=true --prefix /private/tmp/zw-composer-native`；完整 App 验收为 `ZW_AI_TEST_PREFIX=/private/tmp/zw-composer-native node e2e/ai_composer_interactions_native.ts <输出目录>`。验收使用带 `-Dtest-mode=true` 的临时构建；普通构建保持关闭自动化接口。
