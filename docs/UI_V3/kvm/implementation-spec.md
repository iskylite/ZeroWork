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

| selector / 区域 | 1440×900 | 860×480 | 约束 |
| --- | --- | --- | --- |
| `#app` | padding8、gap6 | 相同 | flex column；不使用历史内容槽固定宽高 |
| `.titlebar` | (8,8), 1424×36 | (8,8), 844×36 | 公共壳；最终计算值为36，非历史46 |
| `#ai-edge` | (660,44), 120×6 | (370,44), 120×6 | 沿用公共 AI 入口，居中于内容区；位于标题栏下方6px间隙，不受旧24px最小高度或88px内联宽度覆盖 |
| `#content` | (8,50), 1424×810 | (8,50), 844×390 | grow/min-width0/min-height0，r11，overflow hidden |
| `.console-head` | (8,50), 1424×44 | (8,50), 844×44 | 不收缩；padding10px12px；左侧连接名称 `.kvm-title` / `bmc.title` 为13px/19.5、w700、grow/min-width0，长名称省略；右侧五入口不收缩 |
| `.kvm-tools` | (986,60), 434×24 | (446,60), 394×24 | 右对齐，gap6，五入口 |
| `.kvm-tools button` | 82×24，font12/18 w500 | 74×24，font11/18 w500 | r12；图标14×14，stroke1.7；内部gap4 |
| `#video` | (8,94), 1424×766 | (8,94), 844×346 | 黑底，border/radius/padding0；独立overflow auto |
| `.screen` fit / 1920×1200夹具 | (107.203125,94), 1225.59375×766 | (153.203125,94), 553.59375×346 | scale=min(viewport/frame)，居中，无视频内框 |
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

## 历史三步连接稿（BMC 已停止使用）

以下仅保留此前控件尺寸测量来源。旧 `../connection/index.html?protocol=kvm` 的三步流程不再用于 BMC 创建/编辑，不能与本版原生 BMC 单页做整页对比。其默认直连草稿截图为：`/tmp/zerowork-v032-kvm-reference/editor-dark-1440x900-kvm-create.jpg`、`editor-dark-860x480-kvm-create.jpg`，浏览器同为1488×1040/DPR1/zoom1，均截App内容区。

标准modal相对App(340,154.75)，760×590.5；body padding0/40/20/24，内宽696，grid340+340/gap12px16px，field55.5、label11/16.5、input34/r8，footer62/padding14/24。最小modal(50,40)，760×400；head48/padding12/18，body240/padding0/34/12/18（scrollHeight409），内宽708，grid346+346/gap不变，field/input高度不变；footer54/padding10/18。详细compact计算值为同目录 `editor-compact-metrics.json`。本工作项没有修改连接页源码。


## BMC 单页创建/编辑基准

当前页面为 [`editor.html`](editor.html)，样式与控制器分别为 `editor.css`、`editor.js`。业务依据当前设计§3.2/3.3及主任务明确选择：同一页组织，不强制各协议采用相同步数。本页没有 `.step-nav` / `[data-step-panel]`；公共协议选择器、通用Input/Select/Radio/Checkbox及主题沿用现有连接组件几何，不复制SSH三步流程。SSH子编辑直接挂载既有 `../connection/index.html?protocol=ssh&embed=1`，不重画SSH表单。

字段顺序为：名称/分组 → BMC地址/HTTPS端口 → 用户名/固定密码认证 → 密码/默认保存 → 直连或SSH路径 → 路径预览 → 可折叠显示偏好 → 当前草稿反馈。默认名称、地址、用户名和密码为空，分组未分组、端口443、保存密码开启、direct、fit、只读请求关闭。BMC密码与SSH认证独立。

固定底部为取消、测试连接、临时连接、仅保存、保存并连接。测试/临时允许名称为空，只以endpoint投影当次显示名，临时Envelope.id=0，不回写名称输入、不创建资产；保存两动作要求显式名称。测试只覆盖SSH/TLS、管理认证/发现，不创建视频会话或发送输入。输入与route变化使旧测试失效；取消测试只结束本次测试并保留草稿。编辑已保存连接提示下次新建连接生效。

原型仅产生本地意图回执，不实际写资产或凭据、不开网络连接。回执位于App外，只有非秘密配置；密码不进入回执/URL/存储。`save_password=true`表达默认意图，真实秘密存储交宿主。SSH子编辑返回只引用新asset_id，不继承子SSH自身route；取消保留BMC非秘密草稿，旧draft_revision的子结果不得重挂。

| 区域 | 单页约束 / selector |
| --- | --- |
| 面板 | `.bmc-editor-modal` W760/r14；标准direct H590.5，SSH路径+94、高级展开+67.5，上限710；compact H400；以App区域居中 |
| 固定头/尾 | `.modal-head` H52/padding14px20px；footer H62/padding14px24px/gap8；compact分别48/54，padding12px18px / 10px18px |
| 正文 | `.modal-body` 唯一主scroll owner、grow/min-height0；`.bmc-form-content` column gap12，padding0 40 20 24；compact padding0 34 12 18；不裁固定五动作 |
| 信息字段 | `.fields` 两列/gap12px16px；label11/16.5、gap5，input/select H34/r8；密码填满剩余宽，保存密码66×34、gap16 |
| 访问方式 | `.access-choice` 两卡H61/gap16，直连隐藏路径编辑；预览始终显示本机→各跳→BMC，不显示或引用活跃会话 |
| SSH路径 | `#route-search`筛选已保存SSH资产；`#route-list .route-hop` H51/padding8px10px/gap8，22px序号、34pxSelect及28px调序/删除；最多8、不重复、末项键盘/滚动可达 |
| 显示偏好 | `#advanced-options` 同页折叠区；fit/100%逻辑原尺寸与只读请求独立于SSH配置 |
| 原生映射 | DOM `data-testid` 与 `bmc.editor.*` 一致；信息字段→ui.widgets.Input/Select/RadioGroup/Checkbox，路径行→公共Select及Button，正文→ScrollArea；底部动作交editor controller/宿主，不自行建Session |

可复现URL参数为 `?fixture=blank|direct|routed|eight|edit&size=compact&theme=dark|light|sauber`。外部夹具不属于产品画布；正常控制器仍是同一个editor.js。共享JS没有独立可导入的路径业务renderer，因此本页复用现有route class/Select adapter、几何与SSH子编辑入口，未修改shared/connection源。

单页的最终DOM实测与点击由同工作项主线程浏览器协同完成；HTML负责人已读取JSON并查看最终三张截图。环境为IAB、viewport1488×1040、DPR1、zoom1、fonts loaded。原始只读脚本为 `/tmp/zerowork-v032-kvm-reference/single-editor-measure.js`，结果为同目录 `single-editor-standard.json` / `single-editor-compact.json`，两档 `noSteps=true`。

| 最终实测 | 标准App1440×900 | 最小App860×480 |
| --- | --- | --- |
| 面板相对App | (340,154.75),760×590.5 | (50,40),760×400 |
| header / footer | 52 / 62 | 48 / 54 |
| scroll viewport | bounds760×476.5，clientHeight477，scrollHeight634 | 760×298，scrollHeight626 |
| 外层 `.modal-body` | padding0 | padding0（已修旧compact规则的重复内距） |
| `.bmc-form-content` | W760，padding0/40/20/24，gap12 | W760，padding0/34/12/18，gap12 |
| 信息字段 | 内宽696，340+340，gap16；input340×34 | 内宽708，346+346，gap16；input346×34 |
| 首字段相对App | x364 | x68 |
| 密码输入 | 填满整行扣除66px checkbox与gap16 | 626×34 |
| 固定footer相对App | y683.25,H62 | y386,H54，始终在App内 |

本轮实际点击验证：临时连接免名称（name输入仍空、asset_id=0、display_name=endpoint）；仅保存对空名称标invalid；第2跳上移后preview变为gateway→bastion；8跳数量准确且添加禁用；高级选项展开；waiting管理测试→取消测试→草稿保留。8跳夹具使用正文End后，末行、禁用添加与固定footer均可见。新页的JS语法、HTML唯一ID、本地CSS/JS引用、无步骤导航与限定目录diff检查均通过。SSH iframe保存返回分支未列入本次HTML点击覆盖；不把原生子编辑验证当作HTML接线已经运行的证据。

最终截图绝对路径如下，均已查看。历史 `editor-dark-*` 是已停止使用的三步稿，不能混入当前单页对比：

- `/tmp/zerowork-v032-kvm-reference/single-editor-dark-1440x900.jpg`
- `/tmp/zerowork-v032-kvm-reference/single-editor-dark-860x480.jpg`
- `/tmp/zerowork-v032-kvm-reference/single-editor-dark-860x480-route.jpg`（8跳+End，末项与固定footer可见）

已知平台细差：HTML公共协议picker高40.5，原生公共控件整数41，后续字段可有0.5px取整差；保留公共控件与本地HTML实际值，不为截图一致改写业务布局。静态服务PID34802由本工作项收尾关闭；没有修改shared、connection或原工作树，没有提交Git。

## 定制BMC的只读资源关联状态

实机发现 Manager 的 System 关联可能指向不可用资源。严格KVM映射证明保留失败；仅在已完成、有效的 Systems 集合严格只有一个实际成员，且该资源有效、有身份时，投影其原始逐字段证据供只读查看。映射、写入授权和二次认证能力均不因此提升；多成员、未完成发现或不可靠资源不能走此投影。

HTML新增 `?state=unmapped` 独立模拟入口，电源/启动与BootOrder均显示“该管理资源与当前视频的关联未验证，仅供查看”，字段改称资源状态。主线程在IAB viewport1488×1040、DPR1、zoom1中点击检查了三个入口：启动选择禁用、无执行入口，20项顺序只读；启动气泡相对1440×900 App为 `(1116,92,312,277.5)`。参考为 `/tmp/zerowork-v032-kvm-reference/unmapped-{boot,power,boot-order}.png` 与 `unmapped-boot.json`。此状态不改变原verified基准；原生仍可保留禁用的操作控件，不能据此开放写入。

## 连接进度、连接日志与测试反馈

控制台的连接等待卡显示真实当前阶段、阶段/总耗时和六组步骤：路由、TLS、设备兼容识别、认证与固件、管理发现、视频与首帧。原生根据实际事件标记已经走过的组，不按阶段枚举推断百分比；没有逐跳事件时只描述N跳链，直连不称SSH第0跳。等待证书或凭据明确显示等待用户；失败保留中文解释与静态错误码，取消后仍可查看诊断和按真实释放回执重试。

HTML `?state=connecting&phase=public_script` 为明确的本地阶段夹具，窗口外选择器可切换 `waiting_certificate`、`waiting_credentials` 等阶段；其固定演示耗时不是产品计时器。连接中/失败可打开连接日志，成功后从显示菜单或连接详情进入。日志只属于当前连接尝试，最近32条，包含相对时间、阶段、静态错误与HTTP状态/资源种类等，不记录认证信息、响应正文或会话ID，不写入磁盘。

进度卡从准备连接（原生 progress revision=0）到阶段推进、等待用户、失败、取消与释放后均使用同一固定几何。标准/小窗 App 为 1440×900、860×480；卡片 W520/H441，受视频区 H−24 约束，小窗 H322。padding20、gap12、radius12。以下均为浏览器实际 DOM/computed 值，坐标相对 App；IAB viewport1488×1040、DPR1、zoom1、fonts loaded。

| 区域 | 标准 App1440×900 | 小窗 App860×480 |
| --- | --- | --- |
| 进度卡 | (460,256.5),520×441 | (170,106),520×322 |
| 固定 header | 480×74；标题26 + gap6 + 计时18 + gap6 + 通知18 | 相同 |
| 正文滚动视口 | 480×271 | 480×152 |
| 步骤组 | 480×220；六行H30、gap8；始终为正文第一块 | 相同，可独立滚动看到末项 |
| 路径与完整详情 | 步骤后 gap12；路径padding10/井底，完整详情后置 | 同一正文滚动，不挤动标题与按钮 |
| 固定操作区 | H32；连接日志76 + gap8 + 会话动作槽76 | 相同；取消/重试共用同一槽 |

计时使用静态标签“当前阶段 / 秒 · 总计 / 秒”和两个独立的 64px 数字槽，Menlo12/18、右对齐；秒数增加不移动其他文字。准备连接显示“—”，有实际计时时显示一位小数。等待用户/错误码放预留18px通知行；错误的完整解释仍在正文中，不依赖省略行。`?state=connecting&phase=prepare` 对应初始准备夹具；连接中的原型计时仍是明确的静态演示值，可用 `stage_elapsed` / `elapsed` 参数做长短数字比较，不能当作原生计时器。失败/取消夹具表示已完成释放，原生重试继续以真实 cleanup receipt 决定可用性。重试回到准备连接，卡框和操作槽不移动。

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

连接日志使用760宽公共Modal。标准470.5高，header52、正文356.5、footer62；日志井底696×320，Menlo11/18.7、padding10。小窗330.5高，header48、正文228.5、footer54；日志井底708×200；关闭入口固定。首次打开/关闭重开默认显示最新事件；已在末尾时新事件继续跟随，手动阅读旧记录时保留当前位置。HTML `&log=full` 是显式32条本地模拟夹具，阶段选择更新日志但不制造未来首帧完成。实际 UI 滚动验证：小窗日志 scrollHeight618、viewport200，初开/重开scrollTop418.5；手动上滚到218.5后切换阶段仍为218.5，重新滚到末尾后更新继续停末尾。此记录验证HTML交互，不替代原生32条日志滚动与实机诊断验收。

测试连接的反馈从滚动正文移到footer上方的固定行，替代本文件早期单页测量中的正文高度：标准scroll高442.5、小窗264；panel760×590.5/400及footer62/54保持。反馈行最小34高，padding4/24或4/18、gap12；文字11/17，日志按钮82×26。日志在反馈区，不添加第六个footer动作。原生使用560×384的保留式Modal和200高ScrollArea；最多32条枚举/数字记录，失败/取消后保留，换attempt清空，修改草稿标记旧草稿，迟到结果不成为当前事实，关闭表单释放。HTML标准/小窗与取消保留已点击验证，证据为 `probe-progress-*` 和 `probe-log-*`；原生结果另列验收记录。
