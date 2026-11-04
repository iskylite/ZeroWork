# 0.3 应用内更新原型

功能归属 [V0.3 应用内更新设计](../../DESIGN/V0.3_APP_UPDATE.md)，是 0.3 的组成部分。本目录仍是独立的设计与本地可交互原型，不控制真实进程、不下载更新、不替换应用、不修改用户配置。对应原生实现已接入，实施与验证边界见设计文档末尾；不能将原型模拟回执当作原生验证。

在仓库根目录运行 `python3 -m http.server 5179 --bind 127.0.0.1 --directory .`，打开 [更新确认](index.html?state=confirm&theme=sauber)。评审工具位于产品面板之外，版本、大小、任务与更新说明都是本地 fixture。

## 交互与取消边界

窗口外的「推进模拟回执」用于定格演示下载完成、校验通过、快照保存、任务释放与 helper 回执。默认模式自动推进本地关闭/交接模拟；下载和校验只由模拟回执推进，不制造网络结果。`freeze=true` 关闭自动回执，供竞争、取消与固定画面检查。

- 后台下载/后台检查和窗口 X 只隐藏详情；重新打开仍显示该操作。取消下载删除未完成包；取消校验清除未验证包；晚到结果不能进入 ready。
- 安装先处理全部窗口的未保存内容；返回不关闭工作，放弃须明确选择。随后保存更新前快照，保存失败时工作保持运行。
- 点击「结束任务并安装」后先取得快照回执，再结束工作。取消安装意图不会取消已经发出的关闭回执；取消后仍显示待收尾数量和「查看收尾进度」入口，只读区分已结束、正在结束与继续运行；再次更新接续未结束对象。
- helper 准备就绪不代表提交安装。请求取消后显示等待确认，收到取消 ACK 才返回工作区；提交先被接受时继续显示不可取消的安装阶段。
- 交接失败、退出超时、恢复失败、新版启动失败、数据已变更和再次启动受阻均有独立状态。恢复旧版须同时满足包验证、数据兼容证明与新版进程释放；不满足时无启动旧版按钮。
- 终态恢复错误可收起为「恢复信息已保留」，保留门禁、备份与恢复入口，不显示普通工作区。

这些都是本地设计模拟；计时器只模拟回执，原生产品必须消费真实宿主与事务结果。

## 状态与验证

状态选择器包含原有下载/安装流程，以及 `drafts/saving/snapshot_failed/draining/commit_pending/cancel_pending/handoff_failed/parent_exit_timeout/startup_blocked/recovery_pending/restore_failed/launch_failed/incompatible_data/recovery_saved`。

`theme` 接受共享清单的任意内置 ID；必验 `dark/light/sauber`。`busy=false` 表示无运行工作。状态选择器和运行工作开关会重置 fixture；产品内取消、主题切换和隐藏详情不会重置模型。标准面板为 900×640，最小 860×480 内容区内正文可滚动、底部动作固定。

`model.mjs` 是此 HTML 原型唯一的本地状态模拟，完全位于设计目录，不是生产更新器。定向契约检查运行：

```sh
node --test docs/UI_V3/app-update/model.test.mjs
```

检查覆盖快照先行、关闭中取消与晚到回执、重试去重、准备/提交/取消竞争、退出超时授权撤销、启动门禁、兼容性恢复、错误收起和下载/校验取消。它们不执行文件替换、进程控制、系统锁或持久化，不能作为原生安装已通过的证明。

## 主题与效果图

组件颜色使用共享 `../theme-tokens.css`，主题选择器读取 `../theme-presets.json`；材质复用 `../shared/global-background.js`，图标采用 currentColor。`styles.css` 不定义产品颜色常量。切换主题保留当前状态、关闭进度与任务数量。

「导出当前 SVG」读取已渲染 DOM 的实际坐标和计算样式，导出可编辑文字、形状及图标。所有主题使用同一份结构与布局，不手工绘制多套颜色。导出定格当前状态，不嵌入实时模糊、动画与交互；HTML 是材质、键盘、滚动与行为的权威参考。图片、SVG 导出图与运行日志保存在仓库外，本目录仅保留可编辑原型。

本轮效果稿：[可编辑主题与状态入口](index.html)；单独查看 [Dark 确认](index.html?theme=dark&state=confirm)、[Light 确认](index.html?theme=light&state=confirm)、[Sauber 确认](index.html?theme=sauber&state=confirm)，以及 [Dark 进度](index.html?theme=dark&state=closing)、[Light 进度](index.html?theme=light&state=closing)、[Sauber 进度](index.html?theme=sauber&state=closing)。在 1440×900、DPR 2、100% 页面缩放下，从 900×640 产品面板导出；确认与关闭弹窗的基线尺寸为 520×378（新增异常态按内容计算），标题 16/22、正文 12/18、按钮 32 高。主题/材质变更后以可编辑原型的实际渲染为准。

## 原生映射与验收

设置入口消费现有设置事务，Modal/Button/Progress/Switch 消费实际 vendor API，状态由更新控制器提供。任务结束只调用应用级协调器，视图不直接关闭协议或取消 worker。确认绑定计划与清单修订，异步结果携带 generation。资源释放未知不能以强制重启绕过；远端业务结果与本地资源释放分开记录。

原型只验证状态、主题和交互表达。后续原生仍需完成实施设计 §7 的关闭、替换、恢复与真实窗口验收，不能凭原型或 SVG 宣称自动更新已可用。

修订后的恢复效果：[取消确认](index.html?state=cancel_pending)、[恢复失败](index.html?state=restore_failed)与[数据兼容](index.html?state=incompatible_data)。原型状态为权威入口；效果稿必须由同一 DOM 的计算样式重新导出。

导出单态 SVG 并保存到系统临时目录（`tempfile.gettempdir()`）下的 `zerowork-app-update-previews/<theme>-<state>.svg` 后，运行 `python3 docs/UI_V3/app-update/build_preview_sheets.py`，即可按导出文件内的实际区域元数据重建两份对照图，不需要手调裁剪坐标或主题颜色。
