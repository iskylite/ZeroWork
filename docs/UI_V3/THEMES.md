# 内置主题与终端配色

内置 26 套主题：12 套产品配色、Dark Pro，以及 Catppuccin Mocha / Latte / Frappé / Macchiato、Dracula、Solarized Dark / Light、Nord、Tokyo Night、Gruvbox Dark / Light、One Dark、Rosé Pine。HTML 基准、原生 registry 和快速连接原型共用语义角色。

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
