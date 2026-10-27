> 最新：[主智能体亲自逐项点击与APP/Figma对照](verification/self-click/README.md)。

> [冻结的连接与设置完整模块](FROZEN.md) · [本轮逐项修复与实际验收](verification/round3.md)

# ZeroWork · V3 可交互设计原型

当前分层与范围以[组件组合合同](COMPONENT_MAP.md)及[本轮一致性检查](verification/round2.md)为准：通用组件→功能组件→功能模块→整机；VNC/RDP/FTP独立归未来设计，默认预览保留KVM。

整机融合入口：[启动预览](app/index.html) · [操作与连线](app/README.md) · [集成验证](app/verification/README.md)。

本轮逐项检查：[交互与布局审计](AUDIT.md) · [Zenit落地条件](ZENIT_READINESS.md)。历史记录以本轮实际测量与分模块报告为准。

本目录是 UI 后续落地的 HTML/CSS 基准。按用户最新要求补全完整功能区、模块、组件和未来协议页面；所有内容待用户确认，不以当前 App 是否已经实现限制原型范围。使用 V3 颜色、字体、卡片、窗口与浮层规则，不把旧 V2 页面改名作为新稿。

当前图层透明度基线、公式与验证规则见[图层材质设计记录](LAYER_MATERIALS.md)（2026-10-27）。

## 统一入口与模块

[打开设计中心](index.html)。在项目根目录运行：

```sh
python3 -m http.server 5179 --bind 127.0.0.1 --directory docs/UI_V3
```

浏览器访问 `http://127.0.0.1:5179/`。无需 npm、CDN 或构建步骤。

| 模块 | 交互入口 | 设计范围 |
| --- | --- | --- |
| 终端与文件工作区 | [本地 ZSH](workspace/index.html?mode=local)、[SSH](workspace/index.html?mode=ssh)、[组](workspace/index.html?mode=group)、[SFTP](workspace/index.html?mode=sftp) | 完整窗口、页签、侧栏、底栏、内置命令流、历史、广播、链路、转发、传输、AI |
| 连接与资产 | [连接弹窗](connection/index.html)、[资产管理](connection/index.html?open=none) | 身份/协议/认证、高级配置、多跳、核对测试、信任/失败/重试、分组 |
| 设置 | [八分类设置](settings/index.html)、[Provider 与单行模型条](settings/index.html?state=ai-populated) | 搜索与设置事务、外观、快捷键、网络、传输、AI、插件、通知、数据 |
| 远程桌面和 BMC iKVM | [KVM](kvm/index.html?protocol=kvm)、[VNC](kvm/index.html?protocol=vnc)、[RDP](kvm/index.html?protocol=rdp)、[FTP/FTPS](kvm/index.html?protocol=ftp) | 未来协议配置、视频与输入、控制权、显示、电源、启动、AI与异常 |
| 本地笔记 | [笔记工作区](notes/index.html) | Markdown 双栏、分组与搜索、导入导出、草稿与失败、终端/AI联动 |
| 公共组件 | [独立展板](components/index.html) | 输入/选择/按钮/导航/列表/任务/浮层/通知/工具区的标准状态 |

[功能与组件逐项验收表](COVERAGE.md)是覆盖范围与验证状态的依据；[效果图清单](SCREENS.md)负责图像入口，各模块 README 负责具体行为、状态和原生映射。模块页面是实际可点击产品稿，设计中心仅负责导航。

## 参考来源和优先级

- 用户最新决定：模型条一行；全模块补全；保持 AI 已有总体位置、触发和布局；所有气泡留在 APP 边界。
- 当前 V3 原稿：settings/workspace 的可编辑 HTML、CSS tokens 与实际计算样式。
- 现有 App：实际打开安装版本，核对本地终端、侧栏、连接向导与 AI 浮窗；参考截图见 `verification/reference/`。
- Figma：`ZeroWork · 交互原型`，页 `214:329905`。本轮通过 figma_local 实际读取 AI `416:1912203`、KVM `1066:216592`、创建表单 `1036:216473`、电源 `1066:216976` 等有界节点。精简几何参数见 [figma-reference.json](verification/figma-reference.json)。不修改 Figma。
- 功能契约：`docs/DESIGN/V0.1.1`–`V0.1.8`、插件宿主、BMC iKVM 与 KVM AI，以及项目实际源码。历史“未来模块不出效果图”已由本次明确要求覆盖。

AI 保留 pane 顶部三点入口和默认600×456浮窗；公共窗口以1440×900逻辑像素为标准。控件、字体保持逻辑尺寸；评审工具在产品窗口之外。设置是独立面板，尺寸不能强套到整机窗口。最小窗口和边界状态以各模块约束与覆盖表为准。

## 交互与原生落地

每项设计应能定位入口、操作、等待、结果与失败恢复。补全不以截图数量衡量；不能把一个正常页面当作已经覆盖所有状态。气泡/Tooltip/Menu/Modal依附APP内容区，夹取至少8px边距；锚点随页面滚动和窗口布局更新。

后续原生实现遵循 `zenit-html-ui`：优先复用项目实际 `vendor/zenit` 的 `ui.widgets.*`，颜色和角色经 tokens、styles、recipes 管理。项目工具链 Zig0.17.0，不采用技能旧版0.15.2覆盖实际依赖。HTML控件不等于原生功能已经接通，更不能用WebView替代原生窗口。

本轮仅修改设计原型与说明，不提交Git、不修改原生功能、不替换安装包。确认设计后，原生落地仍需同尺寸真实窗口、输入法、焦点、键盘、滚动、文件选择、凭据和真实网络等验收。

## 模拟边界

Shell、SSH、SFTP、FTP、VNC、RDP、KVM、模型请求、文件系统、Keychain及系统通知均为本地模拟。页面可表达完整流程、草稿、权限和错误，但不代表发生了远程执行、文件传输、电源操作或凭据保存。未来模块明确标注为设计，不误称正式App已支持。

## 历史来源

2026-10-24 原目录删除后从GitHub恢复；历史连接HTML原文件未找回。本次连接稿是依据现有App、Figma和V3规范重新补全的新稿，不冒称恢复失稿。旧 `docs/SPEC/prototypes/v2` 保持历史身份，不参与本轮功能计数。
