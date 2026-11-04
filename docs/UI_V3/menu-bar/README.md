# macOS 菜单栏会话活动

版本归属：[V0.3 设计与实际交付状态](../../DESIGN/V0.3_MENU_BAR_ACTIVITY.md)。效果图：[可编辑总览](effects.html)。

可编辑参考：[index.html](index.html)。从仓库根目录启动静态服务后访问此页面，复用 `assets/macos/AppIcon.png` 透明 App LOGO。

- 菜单栏复用现有 App LOGO，收紧透明留白后主体可见高度 21pt；数字叠加在右上角，白色 9pt 粗体、透明背景，仅数字带约 0.45pt 深灰细描边，角标高 13pt，位于放大后 LOGO 的右上角；不是图标旁的平排标题。0 时隐藏角标，超过 99 显示 99+，提示文字保留完整会话数。
- App 在后台时记录有新活动的会话；同一会话的内容区和 AI 助手共用一项。终端实际输出（包含 Shell 完成标记）、终端结束、AI 回合完成均可产生活动；不使用静默时长猜测命令完成。
- App 返回前台全部清空；保留事件基线，重新进入后台不重计旧活动。计数独立于系统通知授权和系统完成提醒开关。
- 左键显示 App。右键显示活动会话列表与“退出 ZeroWork”；右键本身不请求激活主窗口。会话项保存稳定标识，同名项、页签重排和已关闭来源不会误跳；AI 活动优先定位原助手对话及其所属窗口。
- 会话跳转复用已有保存/放弃设置确认，不丢弃尚未保存的设置；有未保存内容时先呈现原确认流程。
- 退出复用应用现有关闭请求，保留运行任务的关闭确认。

## 列表与 Tab 一致（2026-11-02 新增要求）

右键列表复用 Tab 的图标、显示名称和状态，同一窗口内按 Tab 顺序排列；重命名、状态改变、拖拽排序后同步，当前项可用原生勾选标记。原生已通过 `Workspace.tabPresentation()` 复用实际 Tab 图标资源和状态颜色、模型名称、顺序及当前标记；真实 Local 重命名、拖拽排序与进程退出已验证，原生 NSMenuItem 图标/状态/勾选也已核验。

本目录不保存 PNG 导出图；角标和菜单均由可编辑 HTML 表达，LOGO 引用项目资源目录。

HTML 中的系统菜单外观仅为布局与行为参考；原生采用 AppKit `NSStatusItem` / `NSMenu`，字体、菜单圆角和背景由 macOS 管理。参考的 LOGO 主体高 21px、角标 13px 对应原生逻辑点；原生导出以 Retina 2 倍验证。

验证命令：

```sh
zig build -j2
sh scripts/test_isolated.sh test -Dtest-filter='activity badge' -j2
mkdir -p /tmp/zerowork-menu-bar-render
clang -fobjc-arc -framework AppKit src/platform/macos_menu_bar_tests.m -o /tmp/zerowork-menu-bar-native-tests
/tmp/zerowork-menu-bar-native-tests "$PWD/assets/macos/AppIcon.png" /tmp/zerowork-menu-bar-render
zig build -Dtest-mode=true -j2
node e2e/menu_bar_native.ts /tmp/zerowork-menu-bar-check-new
```

自动化覆盖：内容与 AI 按会话合并、前台清零、旧事件去重、结束无新输出、稳定标识与跨窗口/原 AI 对话路由、原生菜单选择/退出动作、0/1/12/99+ 图像；隔离产品实例用两个真实 Local 会话验证 1→2 及重复输出不加数，并保存原生窗口截图。

需要实际系统点击补验：左键显示与最小化恢复、右键保持后台并打开菜单、选择会话后前台定位并清零、退出时的原关闭确认。设置 `ZEROWORK_E2E_NATIVE_HOLD=1` 可让 runner 保持隔离实例至输出目录出现 `stop` 文件（最多 10 分钟）。当前 CUA 无法连接该临时实例，因此不将接口测试称为实际菜单点击已通过。

用户反馈的前台恢复慢已做正式版主线程采样，分析与尚待量化项见 [0.3 设计 §7](../../DESIGN/V0.3_MENU_BAR_ACTIVITY.md#7-前台恢复延迟分析2026-11-02)。隐藏维护、菜单即时定位及图标缓存的局部修正已通过隔离测试，维护版现已重新打包并更新本机：正式版空白工作区约 7.6% CPU，主线程主要等待系统事件；这些数据与实际点击耗时分别记录。


性能维护复验（独立输出目录，避免与其他会话的构建冲突）：

```sh
zig build -Dtest-mode=true --prefix /tmp/zw-menu-maintenance-build -j2
sh scripts/test_isolated.sh test-ui -Dui-test-filter='hidden maintenance' -j2
sh scripts/test_isolated.sh test-ui -Dui-test-filter='notification countdown' -j2
sh scripts/test_isolated.sh test-ui -Dui-test-filter='notification output never adds' -j2
node e2e/menu_bar_native.ts /tmp/zw-menu-maintenance-native-e2e /tmp/zw-menu-maintenance-build/bin/zerowork
node e2e/menu_bar_idle_native.ts /tmp/zw-menu-maintenance-build/bin/zerowork /tmp/zw-menu-maintenance-idle
```

空闲脚本使用自身临时 App、数据和 RPC；5 秒区间记录实际帧数及进程 CPU，断言空白背景实例低于 12 FPS。它不测量系统菜单点击到 Metal 呈现的耗时，不能据此声称消除了所有激活延迟。


2026-11-02 维护包与当前安装收据：`dist/menu-bar-maintenance-20261102/`。正式包从 20:22:47 的独立源码快照构建，避免混入另一聊天继续进行的 UI 修改。签名、生产环境检查、DMG 校验、包与安装哈希核对均通过；当前 App 已正常启动。详细生产采样与自动化边界见 [设计 §7](../../DESIGN/V0.3_MENU_BAR_ACTIVITY.md#7-前台恢复延迟分析2026-11-02)。
