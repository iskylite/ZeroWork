# 设置剩余原生补验：根线程串行运行

脚本 `e2e/settings_remaining_native.ts` 已准备；本轮只做静态语法检查，未读取 live 实例、未启动窗口、未发送 RPC、未运行验收。实际依赖为仓库 `vendor/zenit`；控件选择与键盘 Select 行为以该源码及安装的公开 Harness client 为准。

运行者独占已运行的真实主 App 窗口，先确认 live.json 的 `{pid,bundle,rpc,data}` 指向预期实例。脚本核对 owner PID，不创建/结束进程、不覆盖 config、不调用 scenario/backdoor、不操作原生 picker。输出目录必须为空。窗口已有 Local 终端和固定多行内容时，A/B/C 主窗口截图更有意义。主窗若还没有终端，由根先通过真实 UI 创建；脚本不会自动输入 shell 命令或制造收费 AI 请求。

```sh
node --check e2e/settings_remaining_native.ts
node e2e/settings_remaining_native.ts --live /absolute/path/live.json --out /absolute/path/empty-dir --fields ui.font_size,ui.line_height,ui.cursor_style
```

开场以 `settings.save` 禁用判断无待保存草稿；通知页显示“已授权”不视为脏状态。若私有配置省略默认字段，先读取真实 font_size Input，改一档并通过正常 Save 触发完整序列化，随后通过同一控件恢复原值并 Save；初始化单独记录截图与状态，原显式标量逐项核对。不会直接写 config。

每字段分别记录 before/target、draft、Save、主窗消费者候选画面、重开、恢复后的截图和树。默认通过原设置控件恢复 before，并再次 Save；所有报告保留52字段映射。三项已有完整基本原生证据复用。失败立即退出，保留实际草稿和现场，不能把失败标成覆盖完成；先看 report 和最后截图，再从 UI 恢复 before。不要向非空目录重跑。截图中的图像/字号/光标效果必须根实际查看。

需要真实消费者使用新值时，只跑相应字段并保留目标，完成受控消费者观察后恢复：

```sh
node e2e/settings_remaining_native.ts --live /absolute/path/live.json --out /absolute/path/empty-stage --fields ssh.keepalive_sec,ssh.term --keep-target yes
# 根通过真实 UI 新建受控 fixture 连接，记录 PTY/peer 日志与主窗证据。
node e2e/settings_remaining_native.ts --live /absolute/path/live.json --out /absolute/path/empty-restore --restore-from /absolute/path/empty-stage/report.json
```

恢复仅处理原报告 `saved_reopened_target_retained` 的字段，以控件恢复记录的 before。异常中断的字段须根查看现场后人工恢复。不要同时运行其他脚本/CUA；原生系统 picker、OS 通知和清理操作交根接管，脚本不会自行触发。

| 组 | 脚本可做 | 根必须补的消费者/边界 |
|---|---|---|
| A 字体/终端 | font_family/size/weight/line_height/cursor/highlight/timestamp 逐字段保存、主窗截图 | 查看真实 Local 文本、行距、光标/高亮/时间戳；字体原值为自定义时保守 handoff，避免无法恢复 |
| B 侧栏 | 保存、关闭后主窗画面、恢复 | 草稿不生效、宽窄 resize 与后续 Save 保留偏好的复用/必要补图 |
| C 背景 | 已有图片条件下 enabled/fit/alignment_x/y 保存与图 | 图片 picker Cancel/替换及源 hash；无图不启用；无可辨识图片时不把 fit/alignment 图当完成 |
| D SSH 默认 | keepalive/timeout/TERM/compression 控件 | 新 fixture 连接的 TERM、超时、保活请求、压缩协商线级证据 |
| E 重连 | auto_reconnect/max/backoff/buffer 控件 | 受控中断、重试次数/时间与缓存标记归属；baseline 父开关禁用时依赖字段 handoff |
| F SOCKS | port/bind 控件 | 新转发真实监听/回环及 Stop 释放；不重复多跳 payload；0.0.0.0 创建监听仍须既有确认 |
| G OTP | otp_modal/totp_autofill 控件 | fixture 挑战 modal/inline/脱敏 peer 记录，禁止未经确认发送 |
| H 传输 | dedicated/window/chunk/tasks/resume/MD5/pacing 控件 | 新确认表默认、真实 JobSpec/队列/文件 hash；download_dir picker handoff；conflict_policy 只有 ask，不能伪造值切换 |
| I AI | permission_mode/redact_ip 控件 | 原 provider/model/key 保持。default_provider handoff 根检查并仅重选原值；新会话权限/脱敏请求证据；不增加付费请求重复验收 |
| J 提示/补全 | error_hint/completion.enabled 开关 | 同 Local 上关闭/开启后新事件截图，已有采纳证据复用 |
| K 通知 | 六字段控件 | 根制造真实事件/owner/tab-dot/静默抑制；OS 授权状态以最新真实授权结果为准，审计中旧 UNErrorDomain1 不作为当前 blocker；横幅/声音/点击归属由 CUA 验证 |
| L 日志 | ring/checkpoint/retention/export_format 控件 | 新隔离 Local 实际容量/checkpoint；retention 仅自有旧文件清理交根；txt/cast SavePanel/实际文件交根，不以保存值宣称消费 |

`control_status` 与 `consumer_status` 分栏。`control_run_complete_consumers_pending` 只代表脚本控件阶段结束，不是52字段原生验收通过。树和 config allowlist 仅作佐证，不能代替图像/网络/OS/真实文件消费。报告不会写出完整 config，也不会读 provider 输入框或打印密钥；保存前后仅在内存按语义比较原始显式 provider/model/key 字段；允许应用正常序列化补齐省略的默认字段，保护值不进入断言输出。
