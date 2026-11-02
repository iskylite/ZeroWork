# BMC 证书信任弹窗

设计基准为同目录 `certificate-trust.html`，复用 SSH 认证组件的 surface、header、field well、footer 与按钮层级。使用仓库实际 `vendor/zenit/src/ui/ui.zig` 和 Zig 0.17.0；未调整 zenit 依赖。原生使用共享 `Modal`、`ScrollArea`、`Button`，材料保持原生文本，可选择指纹及字段值；没有 WebView、整页截图或新增边线。

## 布局合同

以下为 2026-11-01 的浏览器 DOM / computed-style 测量与真实原生 harness bounds，单位分别为 CSS px 和原生逻辑单位。主题为 Dark，fixture 目标是 `bmc.example.test:443`，滚动位置为顶部。

| 区域 | 1440×900 | 860×480 | 约束 |
| --- | --- | --- | --- |
| Modal | (440,110) 560×680 | (150,8) 560×464 | 宽 560、高 680；受视口四周 8px 约束；r14、border 0 |
| 标题区 | 高 40 | 高 40 | 左右 padding12、gap6；18px 图标；标题 13/20 w700；关闭 22×22 |
| Body | padding 8px 12px 12px，gap6 | 相同 | 材料滚动区 grow/min-height0；操作区不收缩 |
| 材料滚动区 | (452,158) 536×580 | (162,56) 536×364 | 整个材料区统一滚动，不把证书原文锁进 120px 小窗口 |
| 指纹 well | 宽 536，min-height56 | 相同 | padding10、gap4、r9、border0；64 位 SHA-256 完整一行 |
| 指纹值 | 宽 516、高 16 | 相同 | 10/16 等宽文本，可选择；不插入省略号 |
| 元信息 | label64 + gap10 + value grow | 相同 | Subject/Issuer 按内容换行；时间 10/16 等宽；其余 11/16 |
| 操作区 | (452,744) 536×34 | (162,426) 536×34 | gap8；拒绝104、仅本次132、保存146；r8；12/18 w500，居中 |

颜色全部沿用 `app_theme.zig` 和 `auth_challenge_styles.zig`。Dark overlay 的浏览器最终值是 `rgb(41 42 48 / 96.0784%)`；字段背景对应 HTML `--control-bg` 与原生 `popupInset()`；次按钮对应 `--popup-action` 与 `popupAction()`；保存按钮使用既有 `action_accent`。验证警告背景使用 warn@23/255；证书或验证例外变化时使用 danger@23/255，并显示明确变化提示。

HTML 使用本地 Inter 字体和系统 Menlo 等宽字体。隔离预览现有 sans 字体实际为 Helvetica Neue，等宽 selector 已显式配置 Menlo；生产应用沿用自身已注册的 Inter / JetBrains Mono。此处不声称隔离预览与生产字体逐字形完全相同。

## 数据与决定

`challenge_host.Payload.certificate_trust` 仅携带公开展示数据。Host 深拷贝所有字符串，指纹按完整 32 字节值复制。保留既有 `material` 文本供其他只读消费者使用。结构化展示要求既有的三个 choice 值依次为 `reject`、`once`、`persistent`；决定仍通过原来的 owner/request/generation 元组提交。

| 入口 / test_id 后缀 | 行为 |
| --- | --- |
| `plugin.challenge.certificate.reject` | 提交 `reject`，停止本次连接 |
| `plugin.challenge.certificate.once` | 提交 `once`，沿用既有仅本次信任范围 |
| `plugin.challenge.certificate.save` | 提交 `persistent`，沿用既有证书、证书链及验证例外持久范围 |
| `plugin.challenge.certificate.close` / Escape | withdraw 原请求，视为取消，不产生接受决定 |
| `plugin.challenge.certificate.scroll` | 可滚到完整 Subject、Issuer、有效期、变化状态与保存范围说明 |

未改变 TLS 验证、不可例外失败、指纹比较、信任缓存或持久化策略。没有自动接受、全局跳过 TLS、对真实 BMC 的测试决定或用户资产变更。

## 验证与复现

```sh
zig build auth-challenge-preview -Dtest-mode=true
ZENIT_E2E_FILE_RPC_DIR=<独立临时目录> ZENIT_E2E_BACKGROUND=1 ZENIT_E2E_ISOLATE_POINTER=1 ./zig-out/bin/auth-challenge-preview dark certificate_tls
zig build test-ui test-bmc -Dui-test-filter='certificate trust' -Dtest-filter='BMC plugin runtime trust' --summary all
```

针对性测试成功：UI 29/29（包含证书 payload 深拷贝、完整材料、按钮居中与可达、三种原请求决定、恢复普通密码表单），BMC 12/12（包含结构化材料映射、拒绝时零凭据读取及原有失败原因）。原生 harness 实际点击拒绝、仅本次、保存，分别收到 `reject`、`once`、`persistent`；关闭和 Escape 都 withdraw 原请求，进程正常退出 0。测试仅使用隔离本地 fixture，无真实网络或信任库写入。

证据目录：`/tmp/zerowork-bmc-certificate-ui/`。最终 HTML SHA-256 为 `e309fbd718ebe828236d92133bf6781a8516a6ed7f7e09de814a8eca916da6e1`；修正字段背景与 dl 默认 margin 后的最终浏览器参考为 `html-final-1440x900.{json,png}`，初次两尺寸测量为 `html-1440x900.{json,png}`、`html-860x480.{json,png}`。原生为 `native-1440x900.{json,png}`、`native-860x480.{json,png}`、`native-860x480-bottom.{json,png}`，行为报告为 `native-report.json`。原生截图物理尺寸为 2880×1800 / 1720×960，backing scale 2。IAB 最终 computed viewport 为 1440×900、DPR1，但截图物理尺寸为 1440×810；因此该截图不作为完全同视口的像素对齐证据，只按实际 DOM / 原生逻辑 bounds 对照，不以整图拉伸或相似度分数宣称一致。生产字体由最终 App 实窗复查。
