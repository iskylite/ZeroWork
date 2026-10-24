# `ui.view`：声明式视图树（Solid 风格 JSX 的 Zig 版）

> Yix（`.yix` / `.yss` 编译到本层）见 [YIX_REFERENCE.md](YIX_REFERENCE.md)。
> Yix / YSS 是可选的：只用 Zig 写组件（参数、受控值、插槽、配方）的完整示例见 [examples/zig_native](../examples/zig_native/README.md)。
>
> 相关：`docs/SIGNAL_API_DESIGN.md`（Signal-first 组件 API）、`docs/STYLING.md`（样式三层模型）。

## 0. 一页结论

```zig
const v = ui.view;
const W = ui.widgets;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const count = try scope.createSignal(u32, 0);
    const even = ui.map(count, isEven);

    return v.render(scope, cx, v.col(.{ .style = S.root }, .{
        v.text(.{ .style = S.title }, "Reactive Counter"),
        v.text(.{ .style = S.count }, v.fmt("count = {d}", .{count})),
        v.row(.{ .style = S.Badge.of(.{ .even = even }) }, .{
            v.show(even, .{"even"}).fallback(.{"odd"}),
        }),
        v.row(.{ .style = S.buttons }, .{
            W.Button(.{ .label = "+1", .on_click = ui.on.update(count, inc) }),
            W.Button(.{ .label = "Reset", .on_click = ui.on.set(count, 0) }),
        }),
        v.each(todos, .id, todoRow),
    }));
}
```

| 问题（改造前） | 现在 |
|---|---|
| 每个子节点 `try parent.appendChild(allocator, try ...)` | 子元素写成 tuple，`render` 一次挂好 |
| 点一下按钮要 `Bindings` 结构体 + `cx.bindState` + `cx.on` | `ui.on.set / toggle / update / assign / call / bind` |
| `Show` / `For` 要包 `struct { fn build }` | `v.show(cond, .{...})` / `v.each(items, .id, row)`，子元素描述值直接存进区域 |
| 组件 `.mount(scope, cx)` + 取 `result.container / .content` | 组件 builder 直接当子元素；`v.with(组件, .{子元素})` |
| 样式：`boxStyled` 只收一个函数，条件样式要自己写 effect | `.style` 收函数 / 字面量 / tuple 合并 / `when` / `hover` / `styleBy` |

模型不变：**没有 VDOM，组件函数不重跑**。元素是值，`render` 一次性挂成保留模式节点树，之后只有细粒度 effect 更新（与 Solid 一致，也与 SIGNAL_API_DESIGN §1.4 的非目标一致）。

## 1. 元素

| 元素 | 说明 |
|---|---|
| `v.box(props, children)` / `v.row` / `v.col` | 容器。row / col 的 direction 恒定（样式里的 direction 被覆盖，主题重放时也是） |
| `v.text(props, content)` | content：字符串 / `v.fmt(fmt, args)` / 任意 `[]const u8` 响应式源 |
| `v.spacer()` | 弹性空白 |
| `v.grid(.{ .columns = &tracks, .rows = &tracks, .column_gap, .row_gap, .style, … }, children)` | CSS grid 布局容器（`ui.GridTrackSize`：px / fr / auto）；子项用样式里的 `grid_placement` 跨行列。与 `W.Grid` 虚拟化数据网格不同 |
| `v.portal(元素)` | 挂到窗口浮层 portal（与 Popover 内容同层，压过整棵文档树、不受祖先裁剪），声明处不占位；随声明处 scope 卸载 / 失败回滚回收 |
| `v.show(cond, children).fallback(children)` | 条件渲染；cond 是 bool 或任意 bool 源（`ui.not(x)`、`ui.eq(page, .home)`…） |
| `v.match(value, .{ .a = ..., .b = ..., .@"else" = ... })` | 枚举分支，编译期检查穷尽 |
| `v.each(items, key, row)` / `v.eachWith(ctx, items, key, row)` | keyed 列表；key 是 `.field` 或 `fn (T) u64` |
| `v.with(组件, children).trigger(children)` | 子元素放进组件 slot / trigger |
| `v.component(f, props)` | 有状态组件：`f(props, scope, cx) !*Node` |
| `v.attrs(.{ .test_id, .a11y, .on_click, .style, .parts, … }, 元素)` | 给任意单节点元素（常用于组件根）补属性；`.style` 叠加在组件样式上，条件撤销回到挂载时快照（不跟随组件后续更新，见下文限制）；`.parts = .{ .dialog = "id", .chrome = .{ .style = S.panel, .test_id = "x" } }` 给组件内部部件（Result 的 `*Node` 字段）设 test_id 或叠属性 / 样式；`v.with(...).parts(...)` 同义 |
| `v.ref(handle, 元素)` | `handle = try v.createRef(scope, T)`；组件 T 为 `v.MountResult(Builder)`，普通元素 T 为 `*ui.Node`。`get()` 返回 `?T`，卸载或回滚清空。持有 scope 必须是挂载 scope 自身或祖先，句柄本身只在持有 scope 存活期间有效；较早挂载的 cleanup 不会清掉后来写入的句柄 |
| `v.capture(&dest, 元素)` | 同步挂载时取一次节点或组件结果，允许栈变量；目标卸载或挂载失败后捕获值无效。跨 show/each 生命周期使用 live ref |
| `v.dynamic(src, f)` | 根据源值重建动态区域；区域拥有内容的 scope，旧内容先卸载 |
| `v.list(array, f)` / `v.listWith(ctx, array, f)` | 静态数组展开成兄弟（不建区域、不建 effect）；数据会变用 `each` |
| `v.items(ctx, slice, f)` / `v.repeat(ctx, n, f)` | 运行期切片 / 次数在挂载时一次展开（不建区域）；`f` 的返回类型要写明（Zig 不能从函数体推导，写不出时包成 `v.component`） |
| `if (cond) 元素 else null` / `v.branch(cond, a, b)` | 静态条件：挂载时决定有无 / 二选一，不建锚点、不建 effect；运行期会变用 `v.show` |
| `v.image(.{ .style, .tint }, texture_id)` | 纹理图像（应用自带位图）；SVG 资源用 `v.icon` |
| `v.append(scope, cx, parent, 元素) !*Node` | 往已有节点追加单根元素，scope 绑在根上（组件「清空后重建」的循环用，不累积 scope）；`v.mount` 的 scope 随调用方 scope 释放 |
| `v.setup(元素, ctx, f)` | 逃生口：挂上后拿根节点做 DSL 覆盖不到的事（底层事件、before_render、自绘） |

**子元素**可以是：上表元素、组件 builder（有 `mount`）、`*Node` / `?*Node`、`null`、字符串字面量（默认主题文本样式）、嵌套 tuple 或数组（fragment，原地展开）。

**写辅助函数**（返回元素的函数）时返回类型要写明：把 props 存成具名常量，用 `v.Text(@TypeOf(props), []const u8)` / `v.Box(@TypeOf(props), Children, null)` 表达；需要 scope 的辅助直接写成 `fn (..., *Scope, *Cx) !*Node` 并 `return v.render(...)`。

**样式字面量**支持嵌套：`.{ .width = .{ .px = 80 }, .padding = .{ .top = 4 } }` 递归转换到 `BoxStyle`。

**props**：box / attrs 收 `style / test_id / a11y（可写字面量）/ on_click / on_hover / on_leave / on_focus / on_blur / visible / focusable / hit_test / tag`，text 收 `style / test_id / a11y / visible / hit_test`，icon / image 另收 `tint`。拼错字段是编译错误，并列出可用字段。文本节点要盒样式（固定尺寸、padding、grow 宽）或事件时，用 `v.attrs(.{ .style = …, .on_click = … }, v.text(...))`。

**文本内容**：`v.text` 把内容拷成节点拥有的堆副本，地址在节点生命周期内稳定（a11y label / live_text 可借用）。`node.getText()` 的副本不带所有权（`owned` 恒为 false），读-改-写换成借用内容是安全的；要问「节点是否已拥有某内容」用 `getTextRaw()`。

**回调型组件**（池化 / 虚拟化，内容由组件按需索取）同样写视图函数：
`W.VirtualList(.{...}).rows(ctx, row)`、`W.Table(.{...}).cells(ctx, cell)`、`W.Grid(.{...}).cells(ctx, cell)`。
行 / 格函数 `fn (Ctx, usize) E`、`fn (Ctx, row, col) E`（ctx 传 `{}` 时省略该参数），或组件形态再加
`*Scope, *Cx` 返回 `!*Node`。每行 / 每格一个子 scope 绑在内容根上，组件回收或刷新该位置时一并销毁。

**行函数**两种形态：视图函数 `fn (T) E` / `fn (T, usize) E`（E 是单节点元素），或组件函数 `fn (T, *Scope, *Cx) !*Node`（行里要建 signal、用 `ui.on.bind` 时；函数体 `return v.render(scope, cx, ...)`）。

## 2. 样式

`.style` 是这一层的核心，把 STYLING.md 的三层模型接进声明式树：

| 写法 | 含义 |
|---|---|
| `S.card` | 具名样式函数 `fn (*const ThemeTokens) BoxStyle`，换主题重放 |
| `.{ .gap = 8 }` | 字面量 |
| `.{ S.card, S.elevated, .{ .gap = 4 } }` | 从左到右合并，后者覆盖前者（`BoxStyle.merge`） |
| `S.Card.of(.{ .selected = selected })` | 推荐：业务状态绑定 cva/sva variant；多 slot 共享同一组变体 |
| `v.when(cond, S.selected)` | 底层条件叠加，仍支持；不作为有限业务状态的推荐写法 |
| `v.hover(S.rowHover)` | 节点悬停时叠加 |
| `v.styleBy(src, S.sized)` | `fn (T, *const ThemeTokens) BoxStyle`，按源值选样式（文本则返回 TextStyle） |

**盒样式的三条执行路径，编译期决定**：

1. 样式编译期可知、且没有响应式部件（`S.card`、`.{ S.card, .{ .gap = 4 } }`）→ 挂 `on_theme` hook，与 `ui.boxStyled` 同等零成本：不建 effect；挂载时按需预分配 StyleExt，不影响 promoted 渲染缓存资格。
2. 只有运行期字面量、不读主题 → 挂载时应用一次。
3. 含响应式 `when`、`hover / styleBy`，或读主题但带运行期值 → 一个 effect 同时订阅条件源与主题 signal，重算后增量应用。

普通 `bool` 的 `when` 在挂载时确定，不因条件本身建立 effect；内部含 hover 等响应式部件时仍订阅。读主题且携带运行期值时，主题更新仍可能需要 effect。

声明式样式在挂载时检查全部条件、variant 与 compound 层，预分配可能用到的 StyleExt；样式函数 / styleBy 无法静态确定字段集合，保守预留。分配失败从挂载错误通道返回，不留到后续无错误通道的 effect 中丢字段。相同 NaN 结果按相等处理；仅颜色变化不触发布局，透明度和变换走合成失效，尺寸变化同时失效父布局。

**样式层叠**：一个节点上的所有运行期盒样式是同一个层叠的层，按层序合成目标值，再与上一次的目标值比较、只应用变化：

| 层（低 → 高） | 来源 |
|---|---|
| 元素 | 元素自己的 `style=`（配方、变体、`_hover` 等状态条件、styleBy） |
| 组件内联 | 组件对节点的命令式写入：`setBackground` / `setOpacity` / `setBorderColor` / `setTranslateX` / `node.setStyleInline(.{…})`；`node.unsetStyleInline(.{…})` 撤掉 |
| 调用方叠加 | `v.attrs(.{ .style })`、`.parts.*.style`、模板里组件元素上的 `style=` |
| 动画 | `ui.view.loop`：独占它驱动的属性，变化立即生效、不进过渡；关掉后按过渡从当前呈现值回到作者层的值 |

所以调用方叠加始终压过组件自己的样式（包括组件的悬停效果）；某层不再声明一个属性时回落到下层（叠加撤销后是组件此刻的值，不是挂载快照），最终回到默认值。组件根被叠加时，组件自己设好的样式成为组件内联层的初值。
各层的首次应用（挂载期间）立即生效、不触发过渡。Debug 构建下，如果代码绕过层叠直接改写层叠管着的字段（`node.style.x = …`），会报出字段名与组件名——改用 `node.setStyleInline`。

**撤销语义**：条件撤销时，被它设置过、而新结果不再设置的字段回落到下层；没有任何层声明时回到 `Style` 默认值（不是停在上次的值）。border 家族（`border` 与 `border_*` 细粒度字段）只要上次碰过就整体复位后重放——否则"base 设宽度、条件设颜色"撤销后颜色会残留。background / opacity 走带过渡的 setter。

文本从主题默认值开始，字面量、css 和 recipe 文本 slot 按声明字段叠加；tuple 与底层 `when` 均支持。完整 `TextStyle` / 返回它的函数覆盖完整文本样式。文本始终依赖主题默认值，因此运行期文本字面量也跟随主题，不能套用上面的“一次性”盒样式路径。文本不接收布局字段或 `_hover` 等交互条件，文字业务状态使用 variant。

TextStyle 覆盖 TextProps 的全部样式字段（含 selectable、等宽 / 斜体 / 符号字体、删除线、text_overflow、fade_right）；富文本 spans 只能挂载后 setText。

BoxStyle 覆盖 StyleExt 的低频字段（同名直通：align_self、min/max 尺寸、aspect_ratio、flex_basis、outline、hit_shape、hit_behavior、overflow_fade、will_change_* 等；另有逐角圆角 `corner_radii`、多层内阴影 `inset_shadows`，以及`z_index`、`inset`、`gradient`、`multi_gradient`、`shadows`（`ui.ShadowList.of(&.{ a, b })`）、
`clip_shape`、`glass`（`ui.GlassParams`）、`composited_group`、`blend_mode`、`flex_wrap`）——都可以出现在样式函数、字面量与条件部件里，撤销时复位。

`when / hover / styleBy` 的样式参数须编译期可知（直接传函数或常量字面量）：Zig 里含函数字段的结构体只能存在于编译期，部件把样式存在类型的 decl 上、字段只存条件源，值才能在运行期保存。

悬停样式与用户 `on_hover/on_leave` 共存；多个内部 hover hook 共享事件分发，各自随 scope 注销。

## 3. 事件：`ui.on`

| 组合子 | 结果 | 分配 |
|---|---|---|
| `ui.on.set(sig, value)` | 点击时设为编译期常量 | 无 |
| `ui.on.toggle(sig)` | bool 取反 | 无 |
| `ui.on.update(sig, f)` | `sig = f(sig)` | 无 |
| `ui.on.assign(sig)` | 带值事件（on_change）写进 signal | 无 |
| `ui.on.call(state, method)` | 同 `cx.on`，不需要 cx | 无 |
| `ui.on.bind(scope, ctx, f)` | 捕获运行期值（行 id 等），ctx 拷进 scope | 一次，随 scope 释放 |

命名为 `ui.on` 而不是 `ui.act`：键盘绑定那套 Action 系统已经是 `ui.actions`。

## 4. 组件接入：`ViewParts`

`mount` 返回 `*Node` 的组件不需要任何改动。返回 Result 结构体的组件在 Result 上声明：

```zig
pub fn viewParts(self: ScrollAreaResult) core.ViewParts {
    return .{ .root = self.container, .slot = self.content };
}
```

- `root`：挂进父节点的节点；null = 组件自己挂到了别处（portal 的 Modal / Sheet）。
- `slot`：`v.with` 的子元素去处；`slot_scope`：子元素归属的 scope（Popover 内容必须随 Popover 自己的 scope）。
- `trigger`：Popover / Tooltip / Menu 的触发器插槽。

需要换挂载方式才有 slot 的组件（Card 的 `mountBody`、GlassBox 的 `mountWithState`）在 builder 上提供 `viewMount`，返回 `ViewParts` 或带 `viewParts()` 的结果结构体（后者经 `v.ref` 或同步 `v.capture` 交给调用方）。`mount` 多带参数的组件给出编译期报错；回调型组件改用 `.rows / .cells`。

已接入：ScrollArea、Card、Modal、Sheet、Popover、Group、Form、AccordionItem、Accordion、VStack、HStack、GlassBox、ControlShell（有 slot）；Tooltip、Menu（trigger，没有内容 slot）；TagsInput、Select、ComboBox、Slider、Rate、Tree、Table、DataTable、Calendar、DatePicker、DateRangePicker、NumberStepper、FileUpload、Grid、VirtualList、Input、Textarea、SnapshotLayer（仅 root）。

**部件**：Result 里的 `*Node` / `?*Node` 字段都是可寻址部件，`.parts` 按字段名写 test_id 或叠属性
（Select 的 `trigger / panel / chevron_down / clear_button / search_input …`、Popover 的 `trigger / chrome / content`、
Textarea 的 `input`…）。运行期按数据生成的子项（RadioGroup 选项、Select 选项与多选标签）在数据项上带 `test_id`。

Accordion 的互斥展开在声明式树里用 `W.accordionItemOpen(open, comptime index)`：
`v.with(W.Accordion(.{ .open = section }), .{ v.with(W.AccordionItem(.{ .title = "A", .expanded = W.accordionItemOpen(section, 0) }), .{...}), ... })`。

## 5. 生命周期合同

- **事务**：元素建好立即挂进父节点（或捕获槽），失败时由事务所有者统一回收——`render` 的根、控制流区域、For 的一行。回收顺序固定：hook 失效 → dispose scope（cleanup 还能看到活节点）→ 释放节点。一次挂载出错即停，所以至多一个"建好却挂不上"的节点，它进 stray 槽，同样在 dispose 之后释放。
- **scope**：`render` 在调用方 scope 下开子 scope，整棵树的 effect 都归它；中途失败时整个子 scope 先销毁，之后再改相关 signal 不会碰已释放节点。
- **借用**：`show / match / each` 把子元素描述值按值存下，条件变化时再挂载。描述值里借用的切片（字符串、数组）必须活得比该区域久——字面量与 scope 拥有的数据天然满足，栈上拼出的字符串不满足。
- **主题 signal**：响应式样式订阅的主题 signal 建在 scope 树的根上（`cx.themeSignal` 的缓存随创建它的 scope 失效，建在短命子 scope 上会悬垂）。

悬停回调通过 `hooks.setHoverHandler` 注册或替换。存在 `useHover` 订阅后直接赋值 `events.on_hover/on_leave` 属于合同违例；`debug` / `safe` 在分发前检查监听链，清理不会覆盖后来直接写入的回调。
