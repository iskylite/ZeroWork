# 内置主题与终端配色

内置 37 套主题：12 套产品配色、Dark Pro，以及 Catppuccin Mocha / Latte / Frappé / Macchiato、Dracula、Solarized Dark / Light、Nord、Tokyo Night、Gruvbox Dark / Light、One Dark、Rosé Pine，以及 Vesper、Flexoki Light / Dark、Everforest Dark Hard / Light Hard、Kanagawa Wave / Dragon / Lotus、Ayu Light / Mirage / Dark。HTML 基准、原生 registry 和快速连接原型共用语义角色。


## 中文纯色主题优化（2026-11-04）

本轮调整午夜蓝、松林、深海、暮紫、余烬、石墨、纸白、暖砂、冰川这 9 套既有预设，保留其稳定 ID、名称与排列；其它 28 套配色保持原值。沿用现有布局、组件和材质策略，调整每套独立的表面、文字、填充动作、状态 ink、终端前景、光标、选区与 ANSI 0–15。

| 主题 | 优化后的方向 |
| --- | --- |
| 石墨 `graphite` | 中性炭灰与钢蓝灰强调；主文字从近纯白收为灰白，填充动作使用更深的钢蓝，避免大块明亮填充抢内容。 |
| 纸白 `paper` | 中性暖白、深灰正文、墨蓝灰强调；取代原橄榄绿，与石墨形成中性深浅组合，终端使用接近纸白的底色。 |
| 午夜蓝 `midnight` | 大面积深蓝收为带少量蓝的炭灰；明亮蓝集中到选中、链接与光标，动作填充单独加深，正文色偏收敛。 |
| 冰川 `ice` | 冷白与钢蓝，正文改为接近中性的深灰；与午夜蓝呼应，减少大面积蓝色染色。 |
| 余烬 `ember` | 暖炭灰、铜橙强调，正文保持暖灰；警告金黄、错误砖红，终端蓝紫使用相配的低饱和色。 |
| 暖砂 `sand` | 奶油砂色与铜棕强调，正文从棕色收向暖深灰；与余烬形成温暖深浅组合，警告与错误各有独立色。 |
| 松林 `forest` | 炭灰暗绿底与微暖文字；强调偏叶绿，成功色偏青绿，避免强调与成功共享相近绿色。 |
| 深海 `ocean` | 深蓝灰底与克制的青蓝强调；减少整屏青色，与午夜蓝的蓝色强调拉开区别。 |
| 暮紫 `plum` | 带少量紫的深灰底、接近中性的灰白文字、灰紫强调；明显紫色集中在局部交互。 |

每套中文主题的终端 ANSI 都单独协调红、黄、蓝、紫、青等色相与明度，不再沿用六套深色主题共用的五个槽位。它们是产品配色，不宣称复刻外部经典主题。浅色 ANSI 使用适合浅背景的深色角色；默认终端前景与选区单独保证可读。

`accent` 保留主题识别色，`action_accent` 提供独立的填充动作色；状态图形与状态小字分别定义。普通文字与辅助文字继续遵守现有对比度合同，不通过降低文字可读性制造层次。实际验收包括无图材质、浮层状态、终端选区、AI 气泡及深浅切换；纯色优化不改变全局透明度或模糊规则。

## 新增主题适配（2026-11-04）

这五个家族共提供 11 个核心版本：Vesper 1 套、Flexoki 2 套、Everforest 2 套、Kanagawa 3 套、Ayu 3 套。Everforest 采用 Hard 的深浅组合；稳定 ID `everforest-dark` 保留，显示名称明确为 Everforest Dark Hard。使用现有原生组件、材质和状态派生规则，26 个 UI 角色与终端配色分别定义。

| ID / 显示名称 | 界面方向与适配 |
| --- | --- |
| `vesper` / Vesper | 中性炭黑、蜜桃橙强调、薄荷青成功色。面板保持中性；填充按钮使用较深的暖橙保证白字可读。ANSI 由原版编辑器配色补齐为终端角色，并非上游官方终端移植。 |
| `flexoki-light` / Flexoki Light | 暖纸白与墨黑文字，青绿强调；与现有 Paper 的橄榄绿强调区分。ANSI、终端默认前景、光标沿用上游 iTerm2；选区改为浅青灰 `#dce8df`，保证默认深色文字可读，状态小字单独加深。 |
| `flexoki-dark` / Flexoki Dark | 暖墨黑、米灰文字与青绿强调，和 Light 保持色系一致；采用官方深色 ANSI，UI 状态文字独立提亮，选区为深青灰。 |
| `everforest-dark` / Everforest Dark Hard | 采用 Dark Hard 的灰绿层次与暖米色文字；区别于 Forest 的深绿色外壳。ANSI、终端默认前景与光标保留来源，UI 三层文字与状态小字提亮，避免浮层和选中态对比不足。 |
| `everforest-light` / Everforest Light Hard | 上游 Hard 暖米白背景与灰绿文字，橄榄绿强调；浅色状态文字加深，ANSI 与默认终端前景保持源配色，浅绿选区保证默认文字可读。 |
| `kanagawa-wave` / Kanagawa Wave | 靛蓝深色、蓝色强调、暖米白文字；与 Dragon 的暖墨灰／黄铜色区分。ANSI 保留 Wave 源色，UI 辅助文字与状态文字提亮。 |
| `kanagawa-dragon` / Kanagawa Dragon | 暖墨灰底与黄铜色强调；保留 Dragon 的低饱和绿、灰蓝、灰粉 ANSI，UI 错误文字单独提亮。终端采用来源默认前景与可见的米色光标；蓝灰选区 `#303e48` 保持默认文字可读。 |
| `kanagawa-lotus` / Kanagawa Lotus | 暖米黄浅色、靛蓝文字与蓝色按钮；保留 Lotus 自有色板与 ANSI，独立加深 UI 的提示、成功与警告文字，选区使用浅蓝灰。 |
| `ayu-light` / Ayu Light | 中性近白底、蓝灰文字、橙色强调；区别于 Flexoki 的暖纸白和 Everforest 的米白。浅色按钮、光标与 ANSI 按可读性加深，不沿用深色版明亮文字。 |
| `ayu-mirage` / Ayu Mirage | 冷灰蓝外壳与金橙强调，和 Midnight 的蓝色强调区分。按上游 Mirage 角色适配 UI 与 ANSI，终端默认文字、选区使用本项目可读版本；不宣称逐槽位复刻上游生成器的终端输出。 |
| `ayu-dark` / Ayu Dark | 采用上游较深的蓝黑底和琥珀强调，明确区别于 Mirage 的较亮冷灰蓝底。UI 与 ANSI 按 Dark 原色角色适配，默认前景、选区分别定义。 |

深浅版本分别定义表面、三层文字、操作按钮、状态 ink、终端前景与选区，不做反色派生。新增 6 套与既有 5 套在主题列表按家族相邻排列。Ayu 的终端 ANSI 是项目按来源角色适配的版本，不宣称复刻上游 YAML 生成器输出。

来源均为 MIT 项目：

- [Vesper / Rauno Freiberg](https://github.com/raunofreiberg/vesper/blob/main/themes/Vesper-dark-color-theme.json)，源文件 SHA-256：`da9e0f65da0199f62246153fb2b521ec549f197d32009532b38d1cf0ead500e4`。
- [Flexoki / Steph Ango](https://github.com/kepano/flexoki/blob/main/iterm2/flexoki_light.itermcolors)，源文件 SHA-256：`5289cec063dfad553767f1e5573193694b9b2d51dc61b71e1b1fe64936cae7a6`。
- [Everforest / sainnhe](https://github.com/sainnhe/everforest/blob/master/autoload/everforest.vim)，源文件 SHA-256：`4ddab3c8d96e29310a21441a797e69a2c520ec074db9c20a7eaea866d8b5a8c4`。
- [Kanagawa / rebelot](https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua)，源文件 SHA-256：`bad6ccb01c34f16d38083c4df2ead9f03536de81d6ab5d95b1bdf4b0f8129240`。
- [Ayu / ayu-theme](https://github.com/ayu-theme/ayu-colors/blob/master/themes/mirage.yaml)，源文件 SHA-256：`da1bc0dab910c8d14a93ce52e8900b421a22d4735895524362e414dfb3834937`。
- [flexoki-dark](https://github.com/kepano/flexoki/blob/main/iterm2/flexoki_dark.itermcolors)，源文件 SHA-256：`69e94108974c728700fbfc8e9df50d9d409ea0e50f6dc4b5afd0206efafe80f2`。
- [ayu-dark](https://github.com/ayu-theme/ayu-colors/blob/master/themes/dark.yaml)，源文件 SHA-256：`331e54ec29839cfad80039663b56fbe669b67b3c8fbfac530d1c41f5e453b040`。
- [ayu-light](https://github.com/ayu-theme/ayu-colors/blob/master/themes/light.yaml)，源文件 SHA-256：`e0b99c9254be89ed3ca1f1097278dfa9be90e39a3cf0456ac7a00ed9b737a8af`。
- [kanagawa-themes](https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/themes.lua)，源文件 SHA-256：`da4cbc68ac2b25a1dcea325da3354396068bb007674c51fac5a9184f08a697cf`。

## 配色约定

- 每套主题包含 26 个 UI 角色。`theme-presets.json`、`theme-tokens.css`、`workspace/quick-connect/palettes.js` 与 `src/config/theme_presets.zig` 保持同源，由 `e2e/theme_palette_contract.mjs` 检查。
- 普通正文、提示、占位符、元信息和辅助小字的实际绘制对比度至少为 4.5:1；`fg_1`、`fg_2`、`fg_3` 保持三层层次。状态文字使用独立的 `*_ink`，不直接使用装饰色或终端 ANSI 色。
- 经典主题的 ANSI 0–15、默认终端前景保留来源配色；光标通常沿用来源，Rosé Pine 为可见度例外，保留已实机验证的明亮 `#e0def4`，而非来源的 `#524f67`。UI 表面、弱文字、操作按钮和终端选区按可读性调整。产品主题 ANSI 为项目配色，Dark Pro 不宣称复刻某个外部终端主题。
- 终端选区按实际 RGBA 与默认前景检查。必要的选区背景为 Sauber `#beddff`、Solarized Dark `#0c1b1f`、Catppuccin Latte `#c3c6d0`、Frappé `#52576b`、Macchiato `#54596f`、One Dark `#3f434c`、Solarized Light `#edede6`。Dark / Light 保留原始选区 alpha。
- 原始 ANSI 中黑色、深灰或重复槽位可能与背景接近；不要为满足 UI 文字阈值而改写来源 ANSI。

## 表面与派生颜色

组件静态、hover、按下、聚焦、禁用、选择、拖入目标与 Tag 随主题统一派生，见[主题状态配色合同](THEME_STATE_CONTRACT.md)。修改基础配色后运行 `node scripts/sync_theme_states.mjs`；`theme_palette_contract.mjs` 与原生主题测试共同阻止生成色过期、HTML/原生漂移及状态碰色。

表面遵循[全局主题合同](GLOBAL_THEME_CONTRACT.md)和[层级材质合同](LAYER_MATERIALS.md)。透明度只作用于表面，文字和图标不随整棵节点树淡化。

图片可见时，六种材质按完整 palette、透明度和实际图片可见性缓存可读 alpha 下限，派生目标为 4.65:1。除七种语义 ink 外，`surface_1` 还检查原终端默认前景，以及既有 `action_accent`、alpha8=15 的输入行高亮合成。Solarized Dark 的 UI `surface_1` 为 `#002833`。

浮层可能覆盖终端显式 truecolor 输出，因此 L1 在无图片时也对任意内容底色提供保护；L2 不得比 L1 更透明。无图其它材质沿用基础曲线。

用户气泡的前景与两个渐变端点由同一 `BubblePaint` 派生，检查 256 个 sRGB 插值步进与实际 8-bit alpha。若黑白前景都不足目标，保留 alpha，将端点共同向所选前景的反色做最小调整。目标为 4.85:1，缓存比较完整 palette 与 alpha。原生实现与 `shared/global-background.js`、`shared/ai-prototype.css` 同步。

可编辑参考入口为 `workspace/index.html?mode=ai&material-t=100&theme=<id>`；`ai/conversation.html` 保留静态对话参考用途。字体的来源、版本和许可见[字体资源说明](assets/fonts/README.md)。

## 经典终端来源

以下是本轮实际取得的源文件；SHA-256 对应本地下载快照，避免上游分支更新后无法定位。Catppuccin 的 UI 基色同时参考[官方 palette](https://github.com/catppuccin/palette/blob/main/palette.json)。

| 主题 | ANSI 来源文件 | 本轮源文件 SHA-256 |
| --- | --- | --- |
| catppuccin-mocha | [原始 TOML](https://raw.githubusercontent.com/catppuccin/alacritty/main/catppuccin-mocha.toml) | `949cef17c3ec50420b82c70b22e3aa2ea0a5d27dfcc13284192bd5284b5db2c5` |
| dracula | [原始 TOML](https://raw.githubusercontent.com/dracula/alacritty/master/dracula.toml) | `e9de3a792548c8112168c1dd18b5651d1ebee2893975cda4ccd9c4c0430c87b8` |
| solarized-dark | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/solarized_dark.toml) | `6c8704addff6b5e153cce82241ae10e6be7104634cb6d1cd2da4f3234ef10f92` |
| nord | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/nord.toml) | `0ca4154de46f4d9e3e4d8523d5f074c722e89b6459426cb4bc21ef4b9872f1b6` |
| Catppuccin Latte | [原始 TOML](https://raw.githubusercontent.com/catppuccin/alacritty/main/catppuccin-latte.toml) | `add4020af6910d8baa02bb765f6e12f631c38c092689815a2549d5acbdca3418` |
| Catppuccin Frappé | [原始 TOML](https://raw.githubusercontent.com/catppuccin/alacritty/main/catppuccin-frappe.toml) | `bac9843f0f984f03928342369564527382aedd1d9f6b49273a2f3bf99e28124f` |
| Catppuccin Macchiato | [原始 TOML](https://raw.githubusercontent.com/catppuccin/alacritty/main/catppuccin-macchiato.toml) | `fd06f991f47937a99331c2fa97aa9476c1b7db0a64a44487bb9aa35f7188507c` |
| Tokyo Night | [原始 TOML](https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/alacritty/tokyonight_night.toml) | `ed637fd21797c5f86baa19f482b2efdeec79fd16ee96a6dcec6901482ec3d318` |
| Gruvbox Dark | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/gruvbox_dark.toml) | `85da5eac732cb89ba0a1d334232b9e255e901f4978d3e5eb5512a71d14116ea7` |
| Gruvbox Light | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/gruvbox_light.toml) | `ee3c1cb05ce8ee655eea45192d7628954cbda562ad4cc3b5f4a38c40cd776586` |
| One Dark | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/one_dark.toml) | `f28996a755f8944f88972cf3850432077b8aa43e7fb39cc5511897598961c5a3` |
| Solarized Light | [原始 TOML](https://raw.githubusercontent.com/alacritty/alacritty-theme/master/themes/solarized_light.toml) | `953aabefdd3892e8361eaa326bf652aeb4d1e7cf506f722101fc727896cabca0` |
| Rosé Pine | [原始 TOML](https://raw.githubusercontent.com/rose-pine/alacritty/main/dist/rose-pine.toml) | `3217929b3cf4d992c0392dae69c9726b3bba13ffde8a471d1727457e48a8d3f5` |

## 维护检查

修改配色后，检查同源颜色、材质合成、终端默认字与选区；界面变化还需运行对应原生测试并查看实际窗口。

```sh
node e2e/theme_palette_contract.mjs
node e2e/theme_material_floor_contract.mjs
zig build test-font -j2
zig build test-appearance -j2
```

原生状态脚本位于 `e2e/`，支持指定构建和输出目录。截图、运行日志、隔离配置及逐次验收报告属于临时产物，不纳入本规范；运行结束后清理隔离配置目录。
