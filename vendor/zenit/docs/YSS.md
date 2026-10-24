# .yss：样式配方文件

`.yss` 是 Yix 的样式配方文件。顶层的 `recipe` / `style` / `mixin` 是样式 DSL，其余照搬为 Zig（import、依赖数据的 `styleBy` 函数）。
它一一对应 `ui.cva` / `ui.sva` / `ui.css`，零运行时：生成的就是原来手写的那些对象字面量（见 [STYLING.md](STYLING.md)）。

- `NAME.yss` → 同目录的双胞胎 `_NAME.yss.zig`，入库；`zig build gen-yix` 生成（编辑器保存时 yix-lsp 也会写），`check-yix`（并入 test-headless）比对过期。
  与同目录 `.yix` 撞名（`card.yix` + `card.yss`）时报错，组件的样式文件约定叫 `styles.yss`。
- `.yix` / `.yss` 里引用源文件名：`const S = @import("styles.yss");`（引用 Yix 组件同理 `@import("card.yix")`），生成双胞胎时编译器换成 `_styles.yss.zig`；
  手写的 `.zig` 不经过编译器，直接 import 双胞胎 `@import("_styles.yss.zig")`。
- 文件里要有 `const ui = @import(...)`（生成代码引用 `ui.cva` 等）。
- 属性名、枚举 / bool 字段的取值写错，编译 `.yss` 时就在原文位置报错（属性名带拼写建议）；token 名随设计系统而定，由 Zig 编译期查表报错并列出可选名。
  属性表来自 `src/yix/style_schema_generated.zig`：由 `ui.BoxStyle` / `ui.TextStyle` / css 的 token 类别表 / 默认主题反射生成，
  样式类型变了运行 `zig build gen-yss-schema`（`check-yss-schema` 并入 test-headless，过期即失败）。

完整上手流程见 [YIX_YSS_GUIDE.md](YIX_YSS_GUIDE.md)，工具安装见 [YIX_EDITOR.md](YIX_EDITOR.md)。

## 编辑器

VS Code 插件（`editors/vscode-yix`，当前 0.5.3）+ yix-lsp：

- 补全：属性（带类型、token 类别、文档）、值（按属性的 token 类别列 token，颜色带色块；枚举值；`transparent` / `mix(` / `rgb(` / `rgba(`）、
  `:` 后的条件名、配方第一层的 `base` / `variant` / `flag` / `when`、`when` 里的维度与选项、插槽块、mixin 与 mixin 参数；
- 悬停：属性的类型与文档、token 的明暗两套取值（按就近的 theme.json，找不到时用默认设计系统）、配方摘要（插槽、变体与选项）、mixin 签名；
- 跳转：mixin 调用 → 声明，`when` 里的维度 / 选项 → 声明，插槽块 → `slots(...)`，mixin 参数；
- 大纲：配方 / 样式 / mixin，配方下列出变体（及选项）、flag、插槽；
- 照搬的 Zig 与 `{zig}` 值由 ZLS 服务（悬停、补全、跳转、诊断，位置经映射回 `.yss`）；
- 在 `.yix` 里对 `S.Card` 跳转：ZLS 落在双胞胎里的位置按段表映射回 `.yss` 里的声明。

## 例子

```
const ui = @import("ui");

/// 卡片根
recipe Card {
  base {
    direction: column;
    background: bg-primary;
    corner-radius: 6;
    transition: background 120ms ease-out, border-color 120ms ease-out;
  }
  variant kind = default {
    default  { border: 1 border; }
    outlined { border: 1 border-strong; }
    elevated { shadow: md; }
  }
  flag selected { border: 2 accent; }
  flag hoverable;
  when hoverable & !selected & kind in (default, elevated) {
    :hover { background: bg-hover; }
  }
}

mixin tone(fg) {
  root { background: mix(bg-primary, fg, 0.25); }
  label { color: fg; }
}

recipe Tag slots(root, label) {
  base { root { gap: 4; } label { font-size: sm; } }
  variant color = neutral {
    neutral { label { color: fg-primary; } }
    accent  { tone(accent); }
  }
}

style title { color: fg-primary; font-size: 14; font-weight: 600; }
```

## 声明

| 写法 | 生成 |
|---|---|
| `style name { … }` | `pub const name = ui.css(.{ … });` |
| `style name($p: T = 默认, …) { … }` | `pub const name = ui.paramStyle(struct { p: T = 默认, …, resolve });`，见「参数化样式」 |
| `recipe Name { … }` | `pub const Name = ui.cva(.{ … });` |
| `recipe Name slots(a, b) { … }` | `pub const Name = ui.sva(.{ .slots = .{ .a, .b }, … });`，各块里按插槽分 `a { … }` |
| `mixin name(p, q) { … }` | 不生成代码；`name(x, y);` 在调用处展开，参数按名字替换（声明顺序不限，禁止递归） |

配方里的段：

| 段 | 含义 |
|---|---|
| `base { … }` | 始终应用 |
| `variant dim = 默认 { opt { … } … }` | 一个变体维度；不写默认取第一个选项。维度名不能与关键字（base / variant / flag / when / in）同名，按含义起名（`variant kind`） |
| `flag dim { … }` / `flag dim { … } else { … }` / `flag dim;` / `flag dim = true { … }` | 布尔维度：块是开着时的样式，`else` 块是关着时的样式（不写为空）；`flag dim;` 只用于复合条件 |
| `when 条件 { … }` | 复合规则；条件 `a & !b & c = x & d in (y, z)`，`in` 展开成多条规则 |

块里：`属性: 值;`、`:hover { … }` 等条件块（`:hover :active :focus :focus-visible :selected :expanded :invalid :disabled`）、mixin 调用、插槽块（插槽配方）。
同一块里后写覆盖先写（mixin 展开后再写同名属性即覆盖）。条件块之间按固定优先级叠加：
base ← selected ← expanded ← hover ← active ← focus ← focus-visible ← invalid，disabled 短路其余一切。

条件用在**普通元素**上时的状态来源：`:hover` / `:active` / `:focus` / `:focus-visible` 由节点自己驱动；`:disabled` / `:invalid` /
`:selected` / `:expanded` 取元素的 `state={.{ .disabled = 源 }}`，没写就取 `a11y` 的同名字段，两处都没有时编译报错。

**命名**：配方 PascalCase；样式、插槽、维度 snake_case，不加 `Style` 后缀（编译器检查）。单个 flag 的两态用 `else`，多个维度组合用 `when`。

配方中 `when … in (…)` 按选项的笛卡尔积展开，每个配方累计最多 4096 条复合规则；超限会给出编译诊断，可减少 `in` 选项或拆分配方。

**两种 `when`**：配方的 `when` 引用维度（`a & !b & c = x`），展开成复合规则；参数化样式的 `when` 引用参数（`$flag & $e = x & {zig}`），按书写顺序叠加。

选项名可以与 Zig 关键字同名（公共枚举里的 `error`），生成 `.@"error"`；维度名、样式名、配方名不行。

## 属性与值

- 属性名是 `BoxStyle` / `TextStyle` 的字段名，连字符写法：`corner-radius` → `.corner_radius`，`font-size`，`align-items`……
- 数字 = 像素 / 原值（`12`、`0.5`、`-2`、`12px`）。
- 名字 = token 或枚举：token 按字段的类别取引用（`bg-primary` → `ui.tokenRef(.color, "bg-primary")`），名字不存在是编译错误，报在 `.yss` 的属性行。
  `column` / `center` / `fit` / `fill` 等枚举同理；宽高的 `grow` = 撑满剩余空间。
- 颜色：`transparent`、`#rrggbb` / `#rrggbbaa`、`rgb()` / `rgba()`（alpha 0..1）、`mix(a, b, 权重)`；`{zig 表达式}` 原样嵌入（逃生口）。
- 简写：`padding` / `margin` 收 1 / 2（竖 横）/ 4（上 右 下 左）个值；`border: 宽 [颜色]`；`shadow: md` 或 `shadow: x y blur [spread] 颜色`，
  多层用逗号分隔（`shadow: lg, 0 32 80 #00000019;`，CSS 顺序，最多 4 层，写入 `shadows`）；
  `transition: …` 整段原文是过渡描述（可以跨行），时长可以是 duration token（`background fast ease-out`）。
- `icon-color`：图标着色，随变体 / 条件走。
- 用在 `<text>` 上的 `style` 可以同时写文字属性与盒属性，自动拆分（详见 YIX_REFERENCE §3.5）；文字唯一的条件是 `:hover`。

## 参数化样式

依赖组件参数的连续值（尺寸、间距、百分比位置、颜色覆盖）写成带参数的 `style`：

```
style stack($gap: f32, $width: ?f32, $background: ?ui.Color, $wrap: bool = false) {
  gap: $gap;
  width: $width ?? fit;            // 参数为 null 时取后备值（普通 YSS 值）
  background: $background;         // 可选参数不带后备：为 null 时不声明（回落到下层 / 默认值，有色 → null 会被抹除）
  when $wrap { flex-wrap: wrap; }
}
style bone($variant: Variant, $width: f32) {
  width: $width;
  when $variant = circular { corner-radius: {$width / 2}; }   // {zig} 里可以引用参数
  when $variant in (text, rect) & {$width > 40} { corner-radius: 4; }
}
```

- 参数 `$name: Zig 类型 [= 默认值]`（支持 Zig 类型别名；命名类型的 bool / 可选类型约束由生成 Zig 检查），没有默认值的必填；参数名是 Zig 标识符（`resolve` / `declared` 保留）。参数表可以换行、带结尾逗号。
- 值：普通 YSS 值、`$p`、`$p ?? 值`（只用于可选参数）、`{含 $p 的 Zig 表达式}`；`mix()` 的颜色操作数也可以是参数。
- `when 条件 { … }`：`$flag`、`!$flag`（bool 参数）、`$e = x`、`$e in (x, y)`（枚举参数）、`{Zig 布尔表达式}`，用 `&` 连接。
  顶层属性是 base，`when` 块按书写顺序叠在上面（后写覆盖先写），不嵌套。
- 是参数的纯函数：不能写 `:hover` 等条件块与 `transition`（交互态和过渡放在同一节点的普通 style / recipe 里，`style={.{ S.a, S.b.of(…) }}`）。
- 只用于盒样式（`<box>`、`<text box=…>`）。
- 用到的参数必须都出现在样式里（没用到的参数是编译错误）。

视图里 `S.stack.of(.{ .gap = gap, .width = width })`：参数可以是值或响应式源（信号、computed），按参数逐项跟随；全部静态时只随主题重算、不建 effect。
手写 Zig 里 `S.stack.resolve(.{ .gap = 8, .width = null, .background = null }, tokens)`。

选哪种写法：闭合的离散状态集（尤其要 `:hover`、插槽）用 `recipe`；连续 / 开放的值、直接取组件参数的值用参数化样式；
只有 Zig 才算得出来的（例如按状态色派生的多段渐变）写 Zig 函数配 `ui.view.styleBy`，函数照搬在 `.yss` 里。
