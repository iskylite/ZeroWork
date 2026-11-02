# 主题与组件状态配色合同

主题评审同时覆盖基础配色、静态层次和交互状态。新增或调整主题时一起派生、一起验证；业务页面不自行选择颜色、混色百分比或按主题名称打补丁。

## 唯一入口与数据归属

| 层 | 来源 | 消费方式 |
| --- | --- | --- |
| 基础主题色 | `src/config/theme_presets.zig`，与 `theme-presets.json` 同源检查 | 定义品牌、正文、语义 ink、表面基色 |
| 组件状态与配对文字 | `src/ui/theme_states.zig` | 原生 `app_theme.states()`；HTML `--state-*` |
| 卡片与浮层材质 | `app_theme.zig` 材质派生及 `GLOBAL_THEME_CONTRACT.md` | 既有 `surface_1/2`、`well`、`overlay`；包含 T、图片和实际层级 |
| 终端选区 | 同主题的 `terminalDefaults` / 导入终端 palette | 独立于 UI 行选中；不改 ANSI、truecolor 与默认终端文字 |

`scripts/sync_theme_states.mjs` 读取原生状态策略与基础色，生成 `theme-states.css` 和 `theme-states.json`。JSON 将状态、静态表面、材质策略和终端选区合并为一份主题评审数据，不产生第二套人工维护配色。`theme-tokens.css` 引入生成 CSS；组件展板和业务原型共用。

## 状态职责

| 对象 | 主题角色 |
| --- | --- |
| 实心主按钮 | `primary/primary_to`、`primary_hover*`、`primary_pressed*` 与 `primary_ink`；渐变两端一起响应状态 |
| 实心危险按钮 | `danger/danger_hover/danger_pressed` 与 `danger_ink`；禁止用状态文字 ink 充当按钮底色 |
| 普通动作、图标按钮 | `action`、`hover`、`pressed`、`focus`；按下不复用 hover |
| 输入 | `control`、`focus`、`disabled`、`tag_danger`、`error_focus`；错误获得焦点仍有独立反馈 |
| 行选择 | `selected`、`selected_hover`；选中后 hover 保留选择身份 |
| 拖入目标 | `drop_target`；与已选择行不同，目标路径提示继续保留 |
| Tag | `tag/tag_ok/tag_warn/tag_danger`；与各语义文字配对；静态标签不伪造交互状态 |
| 选择控件 | `choice_off/on/ink`、`choice_disabled_*`、`choice_thumb_off`；Checkbox、半选、Radio、Switch 共用配对，不靠整组半透明削弱禁用态 |
| 滑块与进度 | `range_track/fill/hover/drag/thumb`、`range_disabled*`，以及 `progress_ok/warn/danger`；轨道与填充一起派生 |
| 语义反馈 | `feedback_info/ok/warn/danger`；背景与既有语义 ink 配对，通用 Alert 与提示区共同消费 |
| 搜索命中 | `search_match/search_match_ink`、`search_current/search_current_ink`；只改变搜索覆盖层，不修改终端 ANSI 与原始内容 |
| 小字 | `muted_ink`；必要时仅增强其在状态表面上的可读性，不修改基础主题正文 |

输入内文字拖选继续使用独立的选区背景与选中文字。`selected` 是 UI 行选择，不是输入或终端的文字选区。

原生通用控件通过对应主题 token 消费角色。HTML 使用生成的实际 RGB，不再单独维护“某些浅色主题 10%、其余 16%”的主题名称清单。自定义导入主题使用同一派生算法；原始 ink 相互矛盾的极端导入色不能由有限混色保证全部约束，不属于内置配色验收结果。

## 验收与修改流程

原生策略目前要求配对文字至少 4.5:1；hover/普通动作、按下/hover、选中后 hover/选中等状态至少 1.12:1；输入焦点/普通输入、拖入目标/选中、错误焦点/错误至少 1.15:1。滑块与进度填充相对轨道至少 3:1，滑块 hover／拖动边缘相邻状态至少 1.12:1；选择控件开／关填充至少 1.5:1；普通搜索命中相对终端基色至少 1.5:1，当前命中相对终端基色及普通命中至少 3:1。禁用选择标记仍要求与底色至少 4.5:1。

这是项目状态辨识下限，不是把所有背景当成文字对比度，也不是完整视觉验收的替代。

生成色保留主题种子，只在不满足该组件的前景和相邻状态约束时，寻找最小 RGB 调整；无主题名称特判。主按钮和危险按钮向保证其文字可读的方向变化。交互填充独立于壁纸透明度，避免 T 增大时反馈随之消失；卡片与浮层继续消费既有材质规则，不能用状态色替换整块内容表面。

调整主题时：

1. 修改基础 palette 或统一策略，不修改生成文件和业务页面混色。
2. 运行 `node scripts/sync_theme_states.mjs`，一起更新全部内置主题的状态色。
3. 运行 `node e2e/theme_palette_contract.mjs`，检查基础色同源与状态文件是否过期。
4. 运行 `zig build test-ui -Dui-test-filter='app_theme.test' -j2`，检查全部内置主题的状态差异、文字配对和 HTML/原生逐色一致；既有材质与终端默认文字/选区测试同时保留。
5. 对受影响组件查看 HTML 参考与真实原生窗口，确认实际绘制没有被渐变、焦点或选中覆盖。

卡片的材质层次、任意图片背景、终端选区范围及不同状态组合仍需随主题评审；基础颜色一致、编译成功或单独的文字达标均不能作为整套主题视觉完成的结论。
