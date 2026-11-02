# V0.3.2 KVM HTML → zenit 合同

本轮会话基准为 `index.html`、`styles.css`、`app.js`；创建/编辑基准为 `editor.html`、`editor.css`、`editor.js`，均复用现有公共组件与主题；依据 `docs/DESIGN/V0.3_BMC_IKVM.md` §11.5，不从历史 Figma 尺寸重建重复身份横幅。原生 API 以项目 `vendor/zenit/src/ui/ui.zig` 和 Zig 0.17 为准；本轮不新增 AI、虚拟媒体或未来协议能力。

## 测量环境与复现

- 2026-11-01，ChatGPT in-app browser；当前工具未公开浏览器版本与实际逐字形字体选择。
- 页面：`http://127.0.0.1:8763/kvm/index.html`。静态服务从本工作树 `docs/UI_V3` 启动，PID 94241；交接前由本工作项停止。
- 浏览器 viewport 1488×1040 CSS px，zoom / visualViewport.scale = 1，DPR = 1，页面 scroll=(0,0)。通过外部评审尺寸选择器将 **App 内容窗口**设为 1440×900 或 860×480，并按 `#app` 的实测边界截取；截图分别为 1440×900 / 860×480 物理像素。
- 测量等待 `document.fonts.ready`，状态 loaded。UI computed font stack 为 `Inter, -apple-system, system-ui, PingFang SC, sans-serif`；remote fixture 使用 Menlo/monospace。未据此声称系统实际逐字形命中了 Inter。
- 默认显式 `data-theme=dark`；三主题都使用现有 `theme-tokens.css` 的最终层叠。字体、图标均为项目现有能力；请求日志确认既有本地 `../assets/fonts/InterVariable.woff2` 加载，未添加字体或图片。
- 详细 DOM bounds / computed styles：`/tmp/zerowork-v032-kvm-reference/measurements.json`；按钮背景：同目录 `button-colors.json`。

## 几何与控件参数

坐标均相对 App 左上；CSS px 对应原生逻辑单位。原生截图 backing scale 不同应仅按已知比例归一，不拉伸布局。

下表保留前轮菜单/控件的测量记录；其中8px/6px壳布局与12px/8px视频留白已由文末“工作区卡片对齐与零padding”合同替代，不能用于当前视频几何验收。

| selector / 区域（历史记录） | 1440×900 | 860×480 | 约束 |
| --- | --- | --- | --- |
| `#app` | padding8、gap6 | 相同 | flex column；不使用历史内容槽固定宽高 |
| `.titlebar` | (8,8), 1424×36 | (8,8), 844×36 | 公共壳；最终计算值为36，非历史46 |
| `#ai-edge` | (660,44), 120×6 | (370,44), 120×6 | 沿用公共 AI 入口，居中于内容区；位于标题栏下方6px间隙，不受旧24px最小高度或88px内联宽度覆盖 |
| `#content` | (8,50), 1424×810 | (8,50), 844×390 | grow/min-width0/min-height0，r11，overflow hidden |
| `.console-head` | (8,50), 1424×44 | (8,50), 844×44 | 不收缩；padding10px12px；左侧连接名称 `.kvm-title` / `bmc.title` 为13px/19.5、w700、grow/min-width0，长名称省略；右侧五入口不收缩 |
| `.kvm-tools` | (986,60), 434×24 | (446,60), 394×24 | 右对齐，gap6，五入口 |
| `.kvm-tools button` | 82×24，font12/18 w500 | 74×24，font11/18 w500 | r12；图标14×14，stroke1.7；内部gap4 |
| `.kvm-video-workspace` | (8,94), 1424×766 | (8,94), 844×346 | grow/min-width0/min-height0；padding12，与工具栏横向留白一致 |
| `.kvm-video-card` | (20,106), 1400×742 | (20,106), 820×322 | 黑底、r11、border0、padding8；overflow hidden |
| `#video` / 原生 `bmc.viewport` | (28,114), 1384×726 | (28,114), 804×306 | 真正可绘制/输入区域；黑底，border/radius/padding0；独立overflow auto |
| `.screen` fit / 1920×1200夹具 | (139.203125,114), 1161.59375×726 | (185.203125,114), 489.59375×306 | scale=min(viewport/frame)，居中，远端画面padding0，保留完整四角像素 |
| `.statusbar` | (8,866), 1424×26 | (8,446), 844×26 | 公共壳；最终计算值26，非历史32 |
| 电源 `.popover` | (1132,92), 296×228.5 | 宽296、右侧clamp12 | r12，padding12，grid gap12；无scrim |
| Boot `.popover.boot` | (1116,92), 312×291 / 373 | (536,92), 312×373 | Disabled高291；PXE+Continuous+Legacy高373 |
| `.pop-field` / Select trigger | 行H32、gap8；trigger180×32 | 相同 | label12/18；trigger12/18，padding5px10px，r8 |
| `.well-row` | Power272×34.5；Boot288×34.5 | 相同 | padding9px10px、r8、font11/16.5 |
| `.pop-head` | 高55.5、padding12 | 相同 | title13/19.5 w700；sticky header |
| `#close-pop` | 27.914×31.5 | 相同 | 当前公共按钮最终值；历史24px命中区并未在HTML实现 |
| `.pop-actions .button` | min78×30、r7、padding3px12px | 相同 | font12/18 w500；公共primary min-height覆盖历史28/r8 |
| `.switch` | 288×24整行命中 | 相同 | track30×18、knob14；label gap8；目标/持续/模式独立草稿 |
| `.certificate-state` | max-width540 | 540×346受控滚动 | 二列材料区74px+grow、gap6px10px；底部决定可滚动到达 |
| `.kvm-boot-order` | max-height240、20项 | 388×240，scrollHeight554 | tabindex0；End后scrollTop314，末项可见；无拖动或写入 |

Popover 重新解析 live trigger 并按 App 边界12px shift/flip；max-height=App高度−24，较高 partial/unknown Boot 气泡向上定位并滚动，执行/查询不被裁掉。外点 / Escape 关闭，返回真实触发按钮焦点。标题/视频本身不缩放。

## 三主题最终颜色

下表是颜色基值和实际alpha，不能将带alpha的背景当作不透明颜色。视频viewport始终 `#000`；本地remote夹具为 `#030306`。

| token / role | Dark | Light | Sauber |
| --- | --- | --- | --- |
| toolbar / well | #0c0c0f / 78.8235% | #ececf0 / 78.8235% | #e2f5da / 78.8235% |
| overlay | #292a30 / 96.0784% | #ffffff / 96.0784% | #f3ffef / 96.0784% |
| foreground | #f4f4f5 | #18181b | #0f172a |
| muted | #a4a4ad | #52525b | #46604f |
| hover | #202026 / 76.4706% | #ececf1 / 76.4706% | #dbf0d6 / 76.4706% |
| primary gradient / 135° | #6164ec → #8457ea | #4f46e5 → #7c3aed | #1345f6 → #2563eb |

Primary文字白；阴影 `0 3px 10px primary@.35`（Light/Sauber为.32），另白18%的 `inset 0 1px 0`。浮层复用公共主题阴影，不在KVM另造材质系统。

## selector → 原生职责

| HTML selector | 原生组件 / 语义 |
| --- | --- |
| `#content`, `.console-head`, `#video` | 宿主内容槽 + ui hstack/vstack；帧区域映射原生纹理sink，非WebView/截图 |
| `[data-tool=control|keys|display|power|boot]` | `ui.widgets.Button`；具备稳定test_id；打开前暂停捕获/release_all |
| `.popover`, `.popover.boot` | `ui.widgets.Popover`；bottom-start offset8，fit_or_scroll，viewport clamp12；保持独立owner |
| `#power-action`, `#boot-target`, `#boot-mode`, `#scale` | `ui.widgets.Select`；选择只改草稿/显示状态，不执行网络写入 |
| `#boot-continuous` | `ui.widgets.Switch`；24px整行命中，checked对应Once/Continuous |
| `#power-execute`, `#boot-execute` | `ui.widgets.Button`；点击冻结目标/动作/草稿/能力revision；运行中和unknown无再次执行 |
| `#power-query`, `#boot-query`, `#management-refresh` | 只读管理查询；unknown不自动重发，partial未取得干净结果前禁写 |
| `#boot-order`, `.kvm-boot-order` | `ui.widgets.Modal` + `ScrollArea`；全部20项与未知原文只读保留 |
| `.certificate-material`, `#trust-once`, `#reauthenticate` | 宿主trust/auth challenge；目标、指纹、错误类型与attempt冻结；当次秘密不进入renderer |
| `#retry`, `#cancel-connect`, `#end-session` | controller连接意图；保留原配置/完整route，新attempt不重放旧输入或写入 |
| `#connection-status`, `#frame-status`, `#input-status` | 同一快照的管理/视频/输入状态投影，不把管理在线视为视频就绪 |
| `notify` → `V3Feedback.show` | 复用宿主通知呈现；原生必须按operation/revision更新同一事实 |

## V0.3.2状态与已做操作

外部 `#scenario` 现在可达：已保存未连接、建立中、首次/过期/变化证书、BMC认证失败、失败、取消、中断保留旧帧、结束、无信号、视频失败但管理在线、视频在线但管理不可用、partial、Power unknown、Boot unknown。场景选择是评审夹具，产品操作仍走同一controller，不添加内容页测试连接入口。

- 三主题：实际切换主题，打开Power并选择重启；打开Boot，选择PXE、开启持续生效、选择Legacy，跨菜单/重开保留草稿。默认无更改禁执行；Disabled只关闭覆盖，不误写None。
- 证书变化：查看目标/有效期/旧新SHA-256，最小窗口滚动至本次接受，进入连接进度，再取消；目标与原路径保留。首次与过期证书材料分别可达，未跳过challenge。
- partial：真实点击Boot入口，字段禁用且无执行；只读刷新后恢复干净状态。
- Boot unknown：仅查询，无执行；查询读回PXE/Once/UEFI，无重发和重启，无更改再次禁执行。
- Power：普通重启执行后accepted冻结；查询后仍无法凭On证明重启完成，继续unknown仅查询。强制断电只有一次风险确认，可取消。
- BootOrder：打开20项只读列表，键盘End使scrollTop=314，末项处在列表可视区内；没有写入/拖动控件。
- 人工控制：申请→评审授权→点击画面捕获；普通Escape保持video焦点并作为远端键；Ctrl+Alt+Escape本地释放，activeElement不再是video。远端Esc菜单已实际点击并显示“组合键 Esc 已发送到当前会话”，菜单关闭。
- 管理/视频分离：无信号/视频失败仍可查看管理工具；管理不可用时保留视频与显示，禁用Power/Boot；中断保留旧帧并明确停止更新；结束不展示伪在线旧画面。
- `node --check docs/UI_V3/kvm/app.js` 通过。未将HTML模拟当作原生或实机验收。

## 截图与已知差异

截图目录绝对路径：`/tmp/zerowork-v032-kvm-reference/`。已保存并查看标准Dark电源、最小Sauber完整Boot等代表图；其余同逻辑状态按主题抽样保存。

- 标准三主题：`{dark,light,sauber}-1440x900-{power,boot}.jpg`（Power重启草稿；Boot为PXE/Continuous/Legacy草稿）。
- 最小三主题：`{dark,light,sauber}-860x480-boot.jpg`。
- 状态：`sauber-860x480-certificate-changed.jpg`、`sauber-860x480-partial-boot.jpg`、`sauber-860x480-boot-unknown.jpg`、`sauber-860x480-boot-order.jpg`、`dark-860x480-boot-order-end.jpg`、`dark-860x480-management-offline.jpg`、`dark-860x480-power-unknown.jpg`、`dark-860x480-disconnected.jpg`。
- 共享 `V3Feedback.show` 当前没有operationId/revision/upsert；重复查询会新增通知。通知位于App(top62,right20,width340,z150)，会与toolbar(y60..84)相交；普通status显示期间与持久error都可能截获入口鼠标。关闭通知后真实点击partial Boot已通过，键盘入口也可操作。已向主任务报告，未修改共享源或另造KVM私有通知；原生宿主必须处理同operation更新与避让。
- 既有AI三点边条在compact下与控制入口左侧相交约28px。已向主任务报告；本工作项未改AI设计、未新增其能力。
- 本地证书和BootOrder均为明确的脱敏夹具；浏览器全屏为原型状态，原生全屏/逐字形fallback/真实帧/实机写入由主任务验证。

## BMC 三步创建/编辑基准（2026-11-02）

当前可编辑基准为 [`editor.html`](editor.html)，样式和控制器为 `editor.css` / `editor.js`。本次用户确认以三步替代此前的 BMC 单页表单。SSH/SFTP 与 BMC 共用 `../connection/wizard-shell.js`、`wizard-shell.css` 的标题协议 Select 和圆点步骤指引；原生对应 `src/ui/wizard.zig` 的注册表 Select 与 `src/ui/connection_stepper.zig`。业务编辑、校验、凭据、测试和保存仍由各协议 provider 负责。

| 步骤 | 内容及动作 |
| --- | --- |
| 连接与认证 | 名称/分组、BMC 地址/HTTPS 端口、用户名、固定密码认证、密码/保存密码。底部取消、下一步；临时连接需要允许名称为空，因此此处只校验端点和用户名。 |
| 连接路径 | 直连或有序 SSH 跳板、添加/调序/删除、新建 SSH 子编辑、路径预览；高级选项保留显示比例（适应窗口 / 原始比例 100%）和以只读模式进入。底部上一步、下一步。 |
| 核对与测试 | 名称、端点、账户、认证状态、高级项摘要与路径，提供返回编辑入口。管理测试和日志由原有控制器处理。底部上一步、临时连接、仅保存、保存并连接。 |

标题旁使用 152×30 的协议 Select，菜单在触发框左缘、下方 4px 锚定，空间不足时按公共组件避让。步骤项按内容宽度排列；两条线填充剩余间距，线两端各留 20px，并与圆点垂直居中。已完成步骤显示勾号，未到达步骤禁用；返回修改保留同一份草稿。

面板宽 760/r14，BMC 标准高 590、最小窗口高 400，上限 710；header 52/48、步骤区 60、footer 62/54 均不收缩。正文是唯一主滚动区；标准内距 top14/左右24/bottom20，小窗 top12/左右18/bottom12。字段两列、列间距16、label11/16.5、input/select34/r8，按钮34/r8；主操作使用主题渐变。步骤、字段和操作区沿用共享主题语义，不增加外框与装饰分区线。

默认名称、地址、用户名和密码为空，未分组、443、保存密码开启、direct、fit、只读关闭。密码不进入摘要、JSON、URL或日志；BMC 与跳板凭据独立。测试与临时连接允许名称为空，runtime Envelope.id=0，不创建资产或回写名称；仅保存/保存并连接仍要求名称。测试只验证 SSH 路径、TLS、管理登录与资源发现，不创建视频会话或发送输入；打开控制台后才验证视频。修改草稿使旧测试失效，取消、迟到结果、凭据回滚与 SSH 子编辑所有权沿用原实现。

HTML 参数：`?fixture=blank|direct|routed|eight|edit&size=compact&theme=dark|light|sauber&step=0|1|2&advanced=1`。原型只生成本地意图回执，不实际写入资产、凭据或建立网络连接。SSH 子编辑复用现有连接 HTML，返回时只引用新 asset_id，不继承子 SSH 的路由。

验证入口为 `e2e/connection_wizard_three_step_native.ts`、现有 wizard UI tests 与 BMC editor tests。原生使用当前项目 `vendor/zenit` / Zig0.17；测试通过不代表实机 BMC 连通性或真实键盘/IME 已验证。旧单页测量和 `/tmp` 截图已不再作为本编辑器的当前几何契约。

## 定制BMC的只读资源关联状态

实机发现 Manager 的 System 关联可能指向不可用资源。严格KVM映射证明保留失败；仅在已完成、有效的 Systems 集合严格只有一个实际成员，且该资源有效、有身份时，投影其原始逐字段证据供只读查看。映射、写入授权和二次认证能力均不因此提升；多成员、未完成发现或不可靠资源不能走此投影。

标准单成员路径继续保留。本轮针对已审查Sugon1.80 profile另核对Root默认资源ID、`ManagerProvidingService`、干净Chassis的ComputerSystems/ManagedBy链接及System的反向Chassis/ManagedBy链接，按明确ID唯一选择管理资源，不选择集合首项或依据跨实体UUID。`resource_association_verified`与KVM的`mapping_verified`分开记录；前者不授予后者或任何写权限。结构与身份完整但携带真实Critical的ComputerSystem可保留其原始字段供查看，Power/Boot明确标注“部分结果”，证据仍为partial、不可corroborate；BootOption的独立有效读取保留各自来源。未知关联、身份冲突或无资源身份的失败响应不投影。

HTML新增 `?state=unmapped` 独立模拟入口，电源/启动与BootOrder均显示“管理目标或读取证据尚未核实，仅供查看”，字段改称资源状态。主线程在IAB viewport1488×1040、DPR1、zoom1中点击检查了三个入口：启动选择禁用、无执行入口，20项顺序只读；启动气泡相对1440×900 App为 `(1116,92,312,277.5)`。参考为 `/tmp/zerowork-v032-kvm-reference/unmapped-{boot,power,boot-order}.png` 与 `unmapped-boot.json`。此状态不改变原verified基准；原生仍可保留禁用的操作控件，不能据此开放写入。

## 连接进度、连接日志与测试反馈

控制台的连接等待卡显示真实当前阶段、阶段/总耗时和六组步骤：路由、TLS、设备兼容识别、认证与固件、管理发现、视频与首帧。原生根据实际事件标记已经走过的组，不按阶段枚举推断百分比；没有逐跳事件时只描述N跳链，直连不称SSH第0跳。等待证书或凭据明确显示等待用户；失败在对应步骤下自动展开中文解释、具体请求上下文与静态错误码，取消后仍可查看诊断和按真实释放回执重试。

HTML `?state=connecting&phase=public_script` 为明确的本地阶段夹具，窗口外选择器可切换 `waiting_certificate`、`waiting_credentials` 等阶段；其固定演示耗时不是产品计时器。连接中/失败可打开连接日志，成功后从显示菜单或连接详情进入。日志只属于当前连接尝试，最近32条，包含相对时间、阶段、管理/视频通道、目标host:port、HTTP方法、安全路径模板、发送/响应头/响应正文/验证阶段、HTTP状态、已收实体字节数和请求耗时。路径只来自受限枚举；动态资源与会话ID统一使用{id}模板，query、headers、凭据、token、设备文字和响应正文均不进入日志，不写入磁盘。首次失败事件及其原始上下文另行保留，cleanup与32条ring轮转不会覆盖它。

进度卡从准备连接（原生 progress revision=0）到阶段推进、等待用户、失败、取消与释放后均使用同一固定几何。标准/小窗 App 为 1440×900、860×480；卡片 W520/H441，受视频区 H−24 约束，小窗 H322。padding20、gap12、radius12。以下均为浏览器实际 DOM/computed 值，坐标相对 App；IAB viewport1488×1040、DPR1、zoom1、fonts loaded。

| 区域 | 标准 App1440×900 | 小窗 App860×480 |
| --- | --- | --- |
| 进度卡 | (460,256.5),520×441 | (170,106),520×322 |
| 固定 header | 480×74；标题26 + gap6 + 计时18 + gap6 + 通知18 | 相同 |
| 固定顶部路径 | 480×59.2（单行路径）；padding10、标题16.5 + gap4 + 路径18.7 | 相同；多跳长路径按实际行数增高，不参与步骤滚动 |
| 正文滚动视口 | 480×199.8 | 480×80.8 |
| 步骤组 | 折叠时480×220；六行H30、gap8；每行是可键盘激活的Button | 相同；失败首次展开并滚到该行，其他步骤仍可滚动查看 |
| 步骤诊断 | 每步仅聚合自己的事件；诊断缩进24、上距4、padding8px10px、Menlo11/18.7、井底、无边线 | 与步骤一起滚动，顶部路径/标题/底部动作固定 |
| 固定操作区 | H32；连接日志76 + gap8 + 会话动作槽76 | 相同；取消/重试共用同一槽 |

计时使用静态标签“当前阶段 / 秒 · 总计 / 秒”和两个独立的 64px 数字槽，Menlo12/18、右对齐；秒数增加不移动其他文字。准备连接显示“—”，有实际计时时显示一位小数。等待用户/错误码放预留18px通知行；错误的完整解释与原始失败上下文位于失败步骤下，不依赖省略行。手动折叠/展开按尝试持久保持，timer、cleanup及日志轮转不会重新展开已手动收起的步骤；新的连接尝试清空折叠状态。`?state=connecting&phase=prepare` 对应初始准备夹具；连接中的原型计时仍是明确的静态演示值，可用 `stage_elapsed` / `elapsed` 参数做长短数字比较，不能当作原生计时器。失败/取消夹具表示已完成释放，原生重试继续以真实 cleanup receipt 决定可用性。重试回到准备连接，卡框和操作槽不移动。

连接卡遵循 [LAYER_MATERIALS.md](../LAYER_MATERIALS.md) 的 L1 表面与无描边规则：border=0、outline=none，不使用描边式阴影；只有整体柔和投影。它的底色与视频井底分开，文字/图标保持完全不透明。局部材质参数如下，不改变公共主题或其他浮层：

当前步骤高亮跟随真实阶段所属的六组工作，不按枚举取最大值或把未完成工作钳成已完成。固件需延后到 Manager 元数据验证时，前置 Systems/Managers/Manager 请求都保持 `firmware_confirmation`；只有 `firmware_verified` 后才进入 `redfish_discovery`，HTTP 事件仍保留各自的资源种类。视频通道的新 TLS 握手使用 `video_tls_handshake`，该通道的证书等待使用 `waiting_video_certificate`，两者都属于第六组“视频会话与首帧”；管理通道 TLS 与证书等待仍属于第二组。证书等待继续显示等待用户，具体阶段标题、耗时与日志都如实保留，不因高亮稳定而省略真实工作。

2026-11-01 原生回归：本地 TLS/Redfish/WebSocket fixture 的旧实际阶段序列含 `web_login → redfish_discovery → firmware_confirmation → redfish_discovery → firmware_confirmation → redfish_discovery` 及 `oem_session → websocket_upgrade → tls_handshake → websocket_upgrade`。修正后实际序列为 `web_login → firmware_confirmation → redfish_discovery → oem_session → websocket_upgrade → video_tls_handshake → websocket_upgrade`，固件验证前没有管理发现阶段；后续视频 TLS 也不重入管理 TLS 组。相同序列通过 production views 的真实 Metal 窗口重放并逐帧读取行状态及行底像素：旧高亮为 `认证 → 发现 → 认证 → 发现 → 认证 → 发现 → 视频 → 视频 → TLS → 视频`，新高亮为 `认证 → 认证 → 发现 → 视频 → 视频 → 视频 → 视频`。对照图 `/tmp/zerowork-kvm-bg/highlight-before-after.png`，原始截图与节点/像素记录为同目录 `trace-before/`、`trace-after/`；这是实际 driver 事件的独立原生呈现验证，不冒充修正后实机连接验收。

此前已在标准 Dark 纯色、小窗 Sauber 纯色及当前主 App 的 midnight/海滩图片/透明度50.2%/全局blur0条件下各取52帧阶段推进截图，连接卡顶部/左右空白区及视频井底逐字节稳定；本次不修改卡片材质、图片、固定几何或全局主题。真实图片只读复用，临时 fixture 均在 `/tmp/zerowork-kvm-bg/`，没有改用户配置。额外键鼠回归验证只有修饰键 flags、没有独立 Shift-down 的 `Shift+Right` 仍发送四条平衡 RFB key（Shift↓/Right↓/Right↑/Shift↑），Ctrl+Alt+Escape 始终先本地释放，不发送退出组合或重复合成修饰键。

| 参数 | Dark | Light | Sauber |
| --- | --- | --- | --- |
| 卡片基础色 | #24242b | #ffffff | #f3ffef |
| 次级文字 | #b8b8c2 | #484852 | #354f40 |
| 当前行强调色/文字 | #8c8ef5 | #4f46e5 | #1345f6 |
| 当前行强调底 alpha8 | 26/255 | 20/255 | 20/255 |
| 整体投影 | 0 16px 48px black/.28 | black/.14 | black/.16 |

卡片透明度读取共享 `--overlay-alpha`，原生使用 `theme.layerAlpha(1)`。基础曲线为T=clamp(全局透明度/100)、alpha8=round(255×(1−(0.04+0.12T)))，但当前主线还按完整背景RGB与各类前景ink的可读性计算下限，实际alpha不能固定为T100的基础值214。合并主线后的原生逐主题实测：T0均为245；T100的Dark/Light/Sauber分别为238/229/231。HTML以 `color-mix` 将本地基础色与共享计算结果合成；blur=max(24px,共享 `--overlay-blur`)。原生对应实际依赖的 `BoxStyle.glass` 背景模糊，保留相同最低24px，intensity/specular/refraction/warp均为0；不使用WebView、整页贴图或窗口桌面采样。普通步骤透明，仅当前行有浅色强调底；路径与动作保留原 well token，不新增内部投影或边框。键盘焦点通过动作底色表达。

前一轮独立HTML基准已读取computed并查看三主题参考截图：T0背景alpha0.960784、border0、outline none、blur24；六行均480px宽且左对齐。该轮T100/B40的214/255记录属于当时基础曲线，不能覆盖合并主线后的上述可读性下限；B40原生实测三主题均为40，前景保持完全不透明。标准/小窗的准备、当前阶段、两种等待用户、首帧等待、路由失败、认证失败、取消、结束九组夹具外框与动作槽尺寸/坐标一致。材料的独立最小页额外使用棋盘背景观察backdrop，不能把合成背景或浏览器截图描述为实机画面；真实zenit窗口的运行与截图另行验收。

连接日志使用760宽公共Modal，并在事件滚动区上方固定显示完整路径与28高列标题。单行路径38.7高、底距12；新版三列的小窗原生Modal760×409.2，header48、footer54、路径708×38.7、日志井底708×200。复用SSH连接日志的10.5px/16px等宽排版与12px正文内距，记录按时间戳86px、消息grow、耗时76px三列组织，列间gap12；每行按内容增高，padding6px0，无边线。长路径增加高度时，事件视口按可用窗口高度缩短，仍保留关闭按钮。首次打开/关闭重开默认显示最新事件；已在末尾时新事件继续跟随，手动阅读旧记录时保留当前位置。HTML `&log=full` 是显式32条本地模拟夹具，阶段选择更新日志但不制造未来首帧完成。实际 UI 滚动验证：小窗日志 scrollHeight618、viewport200，初开/重开scrollTop418.5；手动上滚到218.5后切换阶段仍为218.5，重新滚到末尾后更新继续停末尾。此记录验证HTML交互，不替代原生32条日志滚动与实机诊断验收。

三步编辑器的测试反馈位于第三步footer上方固定行；panel760×590/400、步骤区60及footer62/54保持，正文按剩余空间滚动。反馈行最小34高，padding4/24或4/18、gap12；文字11/17，日志按钮82×26。日志在反馈区，不添加第六个footer动作。原生使用560×384的保留式Modal和200高ScrollArea；最多32条枚举/数字记录，失败/取消后保留，换attempt清空，修改草稿标记旧草稿，迟到结果不成为当前事实，关闭表单释放。HTML标准/小窗与取消保留已点击验证，证据为 `probe-progress-*` 和 `probe-log-*`；原生结果另列验收记录。

## 标准管理生产链与本轮验收

电源和启动菜单继续复用上述HTML的草稿、执行、查询及unknown状态和现有公共组件，不改变材质、几何或新增边线。选择只编辑草稿；执行将冻结目标、动作或Boot参数、nonce及能力版本，通过现有宿主choice取得一次授权。取消批准不派发请求，排队前取消为未发送；发送后取消或断线保留结果未知，只提供GET查询，不自动重发。接受、任务追踪、冲突、拒绝、current/pending和最终回读分别呈现，不能把HTTP接受或PowerState=On单独作为重启成功证据。

`read_only`策略、该操作所需字段不可用或标准管理目标未验证时，仅禁用相应执行入口；只读策略不禁止浏览允许值和修改本地草稿。具体KVM通道映射不作为标准管理目标的附加门禁。响应整体Critical以“设备响应含附加诊断；以下字段按各自读取结果显示”单独呈现，Power/Boot各字段按作用域显示正常值或部分结果。电源与Boot的无分配字段判定复用执行器规则，纯Disabled不要求Target/Mode；无关BootOrder、Power或OEM字段不阻断另一操作。正常策略仍逐次批准及写后回读，实机按用户约束不执行电源或启动写入。BootOrder当前只读是V0.3产品范围。

本轮已查看Dark/Sauber两主题、1440×900/860×480两尺寸共12张真实Metal窗口截图，覆盖partial Boot、Power/Boot unknown、查询后状态及拒绝后反馈，未发现裁切。合成UI证据在`/tmp/zerowork-redfish-management-preview/evidence/report.json`，不得当作实机写入结果；实机原生截图和结构化回执位于`/tmp/zerowork-redfish-readonly-evidence/`，其中`power.png`、`boot.png`为本轮真实只读状态。

按接口手册纠正管理/视频耦合后，原生与HTML的提示统一为“管理目标或读取证据尚未核实，仅供查看”，状态为“视频在线 · 管理条件待核实”；不再把KVM具体映射表述为标准管理前提。仅调整文字与管理目标绑定语义，布局、公共widgets和材质不变。已用最新Debug二进制完成新的只读实机运行并查看Power/Boot截图，文字完整可见；对应回执与截图在`/tmp/zerowork-redfish-standard-evidence/`。339项BMC测试和HTML控制器语法检查通过；标准Session独立采集返回201/Redfish，不能把本轮强制只读视为设备不支持标准电源或启动接口。


## 2026-11-01 顶部路径与分步诊断验收

本轮按用户指定改为“顶部固定路径 → 当前阶段与计时 → 可滚动连接步骤 → 固定动作”。不改变卡片材质、外框与六组工作的真实阶段映射；卡内没有新增边线。HTML URL `?state=failed&failure=http&phase=public_script&hostName=LOCAL%20BMC%20fixture&address=local.synthetic.invalid&elapsed=15&stage_elapsed=15` 为公开脚本HTTP正文超时的本地夹具，`log=full`补足32条演示事件。它不连接任何目标。

最终HTML测量为IAB viewport1488×1040、DPR1、zoom1、fonts loaded。卡片单行路径59.2高，route/header/body/actions之间gap12；header74保持原计时槽。标准App1440×900内card相对(460,256.5)、520×441，body480×199.8；小窗860×480内card相对(170,106)、520×322，route相对(190,126)、480×59.2，body相对(190,283.2)、480×80.8，actions y376/H32。实际zenit 0.17.0本地依赖使用同样逻辑尺寸，Metal截图backing scale2；对应卡片、路径、正文和动作bounds逐项一致。诊断长度受每步事件数量影响，正文由ScrollArea独立滚动；不通过裁剪完整路径补偿。

必要验证已通过：`zig build test-bmc -Dtest-filter='BMC connection progress' -j2`、`zig build test-bmc -Dtest-filter='BMC view' -j2`（共33项对应测试），`zig build bmc-kvm-preview -Dtest-mode=true -j2`及HTML `node --check`。测试覆盖安全请求Context不按每次body-read刷ring、原始失败在cleanup/rollover后保留、事件只聚合到所属步骤、手动折叠不被后续快照重置、标准/小窗路由固定与日志读旧行锚点。保留视频TLS归属第六组、固件验证期间高亮不倒退的已有回归。

私有原生预览每档用全新进程和独立RPC目录验证首次失败自动展开/定位、手动折叠后刷新、重新展开、日志关闭、长路径换行；均正常退出code0，预览没有触及正式ZeroWork窗口，也没有真实网络、凭据或管理写入。已查看以下真实Metal截图及对应HTML参考，资料目录为 `/tmp/zerowork-kvm-progress-steps/`：

- 原生：`native-1440-failure.png`、`native-860-failure.png`、`native-1440-log.png`、`native-860-log.png`、`native-860-long-route.png`。
- HTML：`html-standard-failure.jpg`、`html-compact-failure.jpg`、`html-compact-log.jpg`；computed/bounds记录为`html-standard-metrics.json`与`html-compact-metrics.json`。
- 回执：`native-standard-report.json`、`native-compact-report.json`、两档`native-*-tree.json`与`native.log`。

以上为隔离夹具呈现和交互验收；真实驱动遥测与最终新版安装后的实机连接由主工作项另行验证。


## 视频容器与人工鼠标局部修正（2026-11-01，视频留白方案已替代）

视频工作区复用内容槽已有的主题材质，不在留白处重复叠加表面。外侧12px、内侧8px及圆角11px使用项目现有间距和卡片尺寸；没有边框、outline或描边阴影。圆角裁切只在产品视频卡片上，远端纹理位于8px内缩的矩形ScrollArea中，因此即便远端与视口同比例也保留四角像素。fit仍完整等比例居中；100%仍为1920×1200并可双轴滚动。工具栏最右按钮右边与视频卡右边均在内容槽右侧12px处。

几何使用内层`bmc.viewport`的实际全局逻辑尺寸，图像平移读取ScrollArea已按backing像素取整后的translate值；不加入外侧padding、Retina缩放或第二次scroll。实际原生图像rect的四角与中心分别映射为远端(0,0)/(1919,0)/(0,1199)/(1919,1199)/(960,600)。工作区留白、卡片padding、letterbox与滚动条不产生远端点击。捕获拖动保留原有远端边界clamp与释放行为。Framebuffer、远端PNG导出及AI观察坐标空间均未修改，保持远端原图尺寸。

人工mouse move保留60Hz合并窗口；当最后一个move进入pending时，安排该窗口剩余时间的原生redraw deadline，before-render到期后flush，不再依赖33ms普通console poll或下一次move。服务层既有同button mask的连续移动合并和button/wheel/key顺序保护已验证，无证据要求更改队列。此处只证明本地提交和坐标行为，不将本地synthetic Harness时序表述为实机输入往返延迟或实际视频帧率。

验收资料位于仓库外`/tmp/zerowork-kvm-video-surface/`：`html-{standard,compact}-measurements.json`与对应PNG为in-app browser实测（viewport1488×1040、zoom1、DPR1、fonts loaded）；`native-{standard,compact}-geometry.json`及对应PNG为production views + Metal FrameSink隔离夹具（逻辑1440×900/860×480，PNG2880×1800/1720×960，backing2）。原生卡片/viewport与HTML完全同尺寸，fit图像仅有浏览器1/64px布局取整差：原生1161.6×726 / 489.6×306，HTML1161.59375×726 / 489.59375×306。已查看真实原生截图，远端夹具是明确标记的合成网格。原生100%滚动和小窗连接进度另存独立截图。`zig build test-bmc -Dtest-filter='BMC view' -j2`通过30项；必要的原生交互结果见`native-report.json`（passed，正常退出0，budget_used=0、keys=0、buttons=0）；pointer coalesce专项另通过3项。未操作正式`/Applications/ZeroWork.app`或外联BMC，未据此声称实机帧率/端到端延迟已验收。


## 2026-11-01 追加纠错：当前阶段自动定位与三列日志

连接进度现在在实际stage变化时，用原生ScrollArea的nearest对齐确保当前步骤头及已展开详情开头可见；同group内的TLS/证书、WEB/固件、视频各phase变化也检查可见性。仅timer、elapsed或同阶段revision变化不触发定位，用户可以停留在旧步骤。首次失败仍展开并start对齐一次。顶部路径与底部动作固定，未修改后来加入的视频12px外留白、r11、8px内padding、真实image rect或鼠标deadline修复。HTML控制器同步此行为，阶段夹具切换不再强制恢复旧scrollTop覆盖自动定位。

日志从整块Text改为最多33个保留式原生行（32条ring加必要的原始failure摘要），每行分别挂载timestamp/message/duration节点。样式复用`ui/connection_logs_styles.zig`的SSH等宽字体与行结构，时间格式复用SSH `forward_diagnostics.formatTimestamp`并将Zig0.17带符号的数字字段规范为HH:mm:ss.SSS。REALTIME独立采样到`started_unix_ms`与`at_unix_ms`；request/phase duration继续由MONOTONIC计算。缺失wall clock的旧数据明确显示“时间未知”，开始事件未完成时耗时显示“—”，不把elapsed伪装为时钟。消息列完整换行，含目标、通道、method、安全path、请求phase、HTTP及静态错误；耗时独立右对齐，不重复塞进消息。

滚动阅读锚点改为event sequence加行内位置，不再依赖大段Text的byte/line offset。关闭重开默认看最新；末尾跟随，阅读旧行时ring淘汰或行换行保留同一事件。原始failure的sequence、wall timestamp与duration在cleanup和ring轮转后仍保留。HTML三列行也保存可见行锚点。

必要定向检查已通过：BMC view过滤32项、BMC connection progress过滤8项；其中新增14个连续stage在小窗中均完全可见、同阶段手动滚动不被timer重置、同group新phase重新定位、独立wall clock与monotonic duration、三列真实节点bounds、ring轮转锚点。private native连续回放的证据为`/tmp/zerowork-kvm-progress-active/report.json`，阶段截图`redfish_discovery-860.png`与`awaiting_first_frame-860.png`。

三列原生窗口已在1440×900、860×480两档实际检查：时间戳86px、耗时76px，消息只在中列换行，错误上下文完整且关闭按钮可点。截图及节点树在`/tmp/zerowork-kvm-log-columns/native-{1440,860}-columns.png`与`native-{1440,860}-tree.json`，`report.json`为ok=true、sizes=2、exit=0。预览仅使用明确标记的本地合成fixture，独立进程正常退出，不替代完整App最终实机验收。

HTML最新版已过node语法检查；本轮末尾CUA浏览器列表为空、IAB不可用，因此未重新声称新版三列HTML的computed/bounds与截图已经验证。此前HTML几何记录仅覆盖改版前连接卡。生产native在上述真实窗口中的行结构/截图已验证；最终完整App的实机检查交主工作项。


## 2026-11-01 工作区卡片对齐与零padding（当前合同）

按用户最新截图取消视频外侧12px与内侧8px留白。`bmc.content`使用专用`workspaceRoot`复用共享`shell_styles.pane`的L1颜色、grow约束和r11；不重复绘制宿主已有shadow/inset shadow，不新增blur、边框或全局主题改动。圆角clip覆盖工具栏及整个工作区四角。该节点位于`workspace.plugin.content`内层，因此`AppNavHost`清空非终端shared pane/tab root背景后仍恰有一次L1。通用`S.root`继续用于菜单内部，不套用工作区材质。

`bmc.video_workspace`、`bmc.video_card`和`bmc.viewport`四边完全重合，padding全部0；视频viewport与真实frame节点均r11，border width0。fit只等比例居中，letterbox是比例留白；100%仍为远端1920×1200及本地ScrollArea。视觉圆角按本次要求裁切角部，未对Framebuffer、PNG导出或AI观察原图做缩放/裁切。原图坐标空间与输入几何继续使用实际viewport和已按backing像素取整的content translate，只应用一次滚动偏移。

HTML新增等价内层`.kvm-content-surface`，避免公共theme对`.graphic-content`的透明规则清空局部L1；只在KVM页面同步共享壳5px外边距、8px间距、238px展开侧栏。`?sidebar=shown`只提供本地对齐夹具，默认仍收起连接库。

本次私有原生fixture直接复用共享shell的root/title/body/sidebar/pane/status，在renderer挂载后按完整App路径清空shared pane和tab slot背景，已查看真实Metal窗口。原生输入与尺寸切换使用CUA，回执仅通过该进程独立file RPC读取；没有操作正式ZeroWork窗口或连接真实BMC。初始1440×900被当前macOS桌面限制为实际1440×889，如实以该逻辑高度验收；紧凑通过系统Window菜单切到精确860×480。两档HTML使用已有integrated布局在仓库外iframe夹具匹配实际原生尺寸，父viewport1488×1040、DPR1、zoom1、fonts loaded；原生backing2。

| 区域 | 原生/HTML标准1440×889 | 原生/HTML紧凑860×480 |
| --- | --- | --- |
| 顶栏 | (5,5), 1430×36 | (5,5), 850×36 |
| 侧栏 | (5,49), 238×801 | (5,49), 238×392 |
| shared pane / slot / 内层工作区 | (251,49), 1184×801 | (251,49), 604×392 |
| 视频workspace / card / viewport | (251,93), 1184×757 | (251,93), 604×348 |
| fit原图显示rect | (251,101.5), 1184×740 | 原生(274.6,93), 556.8×348；HTML仅1/64px取整差 |
| 底栏 | (5,858), 1430×26 | (5,449), 850×26 |

因此工作区顶部/底部与侧栏完全对齐，右边与顶栏/底栏右边相同，壳间距均8px。零padding的四角、letterbox及两档bounds均已实际检查。32项BMC view测试通过，覆盖连续逻辑坐标的四角(0,0)/(1919,0)/(0,1199)/(1919,1199)、中心(960,600)、100%双轴滚动一次映射及本地滚动条；`bmc-kvm-preview -Dtest-mode=true`构建与HTML`node --check`通过。CUA实际中心回执为(960,600)，100%纵滚480后点击(553,267)映射为(302,654)，与frame全局rect(251,-387),1920×1200一致。fit缩小到0.29时CUA像素取整可达的右/下角为1918/1198，未把它描述成每个远端原始像素都能在缩小显示中独立点击。CUA方向right产生了纵向滚动，故双轴精确回归依据原生Cx测试，不伪称本轮CUA验收了水平滚动。

证据目录`/tmp/zerowork-kvm-card-alignment/`：`native-standard.png`、`native-compact-final.png`、`native-compact-original-scrolled.png`为真实Metal截图；`html-standard.jpg`、`html-compact.jpg`为同逻辑尺寸HTML参考；对应`*-geometry.json`、`html-*-metrics.json`、`cua-input-trace.json`和`report.json`保留数值及检查结果。这些均为LOCAL SYNTHETIC夹具，不能替代整机安装后的实机验收。


## 2026-11-02 默认 FPS 浮层

- HTML 已通过浏览器实测：视口 1210×785 CSS px、DPR 2，紧凑 App 860×480；浮层 94.984×46 CSS px，距视频顶部/右侧各12，padding 6×10，gap 2，r7，11px/16px Menlo/monospace；主/次文字 #f3f4f6/#c6cad1，背景 rgba(18,20,24,.78)。截图 `/tmp/zerowork-mouse-latency-20261101/fps-html-reference.png`。
- 每个 KVM 视图默认启用；“显示 → 显示 FPS”使用原生 Switch，可随时关闭。浮层绝对定位，不改变视频缩放、滚动及输入几何，鼠标穿透；未取得视频时隐藏。
- “显示”按成功窗口提交中的新 generation/revision 去重，窗口空重绘不计数；代表提交呈现频率，不声称物理屏幕扫描 FPS。“解码”使用 Controller 的完整 CPU 帧成功发布累计值；因 lease 占用跳过发布的已解码更新不计入，内容未改变的成功发布仍可计入。它不是所有收到的 FBU 数，也不把 socket 读取次数当帧数。
- 最近1秒计数采用100ms桶，每500ms刷新文案，是近似滚动值；严格性能对照使用累计发布次数差/实际经过秒数。首秒为“—”，无新帧后归零。菜单附最近10秒已完成帧间隔最大值和距上一显示帧时间；无新帧不直接判定卡顿。重连/新代重置统计。
- 传输调度、App 本地 64 KiB 缓冲、背压处理及实测归因边界见 [BMC iKVM 设计 §6.5](../../DESIGN/V0.3_BMC_IKVM.md#65-视频吞吐与-fps-优化设计)。厂商 Web 的原始帧计数标签须先统一时间口径再比较。

## 2026-11-02 临时连接保存与已保存配置编辑

- 左栏继续显示已保存的连接配置。临时 KVM 页签右键提供“保存连接配置”，复用现有连接编辑器，预填名称、地址、端口、用户名与连接路径；临时密码和运行时凭据引用不进入草稿，“保存密码”默认关闭。
- “仅保存”后左栏新增配置，不创建新的 KVM 会话，也不改变当前临时会话的身份。已保存 KVM 页签通过稳定资产 ID 定位“编辑主机配置”，不依赖 SSH 专用的 `host_snapshot`。
- 沿用现有菜单、连接表单及 HTML 布局，无新增视觉样式。隔离完整 App 的原生窗口已验证临时保存、空密码草稿、左栏新增与已保存配置编辑；保存前后 session handle、generation、tab 和 create operation 保持一致。1440×900 逻辑尺寸、2 倍像素截图及回执位于 `/tmp/zerowork-kvm-integration-20261102/sidebar-native/`。本地合成端点验证不代表真实 BMC 连通性验收。
- 同一入口覆盖临时 SSH/SFTP：从原页签冻结的 `host_snapshot` 生成 Envelope，不读取当前选中的左栏资产；保留端点、认证方式、路由和连接选项，移除密码、私钥口令、TOTP 及对应运行时引用，“保存密码”默认关闭。仅保存沿用现有资产事务，不创建会话或改写原临时会话归属；本地终端无远程配置保存入口。SSH/SFTP 冻结快照与无凭据 Envelope 的定向回归通过；当前快速连接只创建临时 SSH，SFTP 的临时来源覆盖由直接快照回归验证。
- 补齐后的完整 App 后台原生回归验证了临时 SSH 保存、已保存 SSH 页签编辑、临时 iKVM 保存回归与本地菜单排除；仅保存前后 session/generation/create operation 及 SSH 页签节点均保持一致，正常退出码为 0。1440×900、2 倍像素截图与回执位于 `/tmp/zerowork-live-fps-20261102/all-temp-save-native/`，全部连接尝试仅访问本次隔离回环端口，无真实远端操作。


## KVM 内部对齐与连接状态入口

本节替代前述44pt工具栏、视频独立四角圆角及独立断开按钮的布局约定。

- 外框占满公共内容槽。标题栏高48，padding上下12、左右13，按钮高24；标题与左栏标题行的几何中心均距外框顶部24。主机名前复用monitor图标18×18，与名称间隔8；名称可收缩并省略。
- 视频外围padding0，填满标题栏下方区域。视频卡片、滚动viewport和远端帧不再各自使用四角圆角，统一由r11外框合成裁切。HTML壳间距与原生保持5pt。
- 连接状态入口位于主机名与五个工具入口之间，采用“图标＋文字”：宽82、高24、图标14、间隔4、左右padding8；标准字体12px，紧凑字体11px。固定宽度避免状态或hover文字切换时移动相邻工具。
- 默认显示已连接、连接中、连接失败或已断开，分别使用circle-check、loader-circle、circle-x或unplug。可操作时，hover或键盘聚焦切换为断开连接；连接过程中显示取消连接。状态详情保留在无障碍名称中。
- 点击先打开440pt宽的确认Modal，显示当前主机名和操作说明。返回、Esc、关闭均保留连接；确认后重新检查当前owner的可操作性，调用现有cancel并去重。连接过程中使用“取消连接？”确认文案。没有可取消的连接或正在清理时不提交操作，状态保持可读。

下表为默认238pt侧栏、底部状态栏可见时的逻辑尺寸：

| 相对App的区域 | 1440×900 | 860×480 |
| --- | --- | --- |
| 左栏 | (5,46),238×818 | (5,46),238×398 |
| KVM外框 | (248,46),1187×818 | (248,46),607×398 |
| 标题栏 | (248,46),1187×48 | (248,46),607×48 |
| 视频viewport | (248,94),1187×770 | (248,94),607×350 |
