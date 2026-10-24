# Yix 与 YSS 语言参考

zenit 的两门声明式源语言，都编译成普通 Zig，零运行时：

| 语言 | 文件 | 写什么 | 编译成 |
|---|---|---|---|
| **Yix** | `.yix` | 组件：参数、状态、模板（类 JSX 标签）、事件 | `ui.view` 的组件与元素描述 |
| **YSS** | `.yss` | 样式配方：类 CSS 的属性块、变体、条件、mixin | `ui.css` / `ui.cva` / `ui.sva` 对象字面量 |

本文是当前 Zig 0.17.0 兼容分支的语言参考，语言限制见 §2.13 和 §3.7。
首次使用请先读 [Yix/Yss 开发指南](YIX_YSS_GUIDE.md)，Windows 构建见 [WINDOWS_BUILD.md](WINDOWS_BUILD.md)。
底层 `ui.view` 见 [VIEW_DSL.md](VIEW_DSL.md)，样式系统见 [STYLING.md](STYLING.md)，YSS 详见 [YSS.md](YSS.md)，
编辑器见 [YIX_EDITOR.md](YIX_EDITOR.md)，用 Yix 写内置组件的约定见 [YIX_COMPONENTS.md](YIX_COMPONENTS.md)。

---

## 1. 工程模型

### 1.1 双胞胎生成物

每个源文件旁边有一个**生成的双胞胎**，入库：

```
card/
  card.yix          ← 手写
  _card.yix.zig     ← 生成，勿改
  styles.yss        ← 手写
  _styles.yss.zig   ← 生成，勿改
  mod.zig           ← 手写：pub const Card = @import("_card.yix.zig").Card;
```

- 命名规则只有一条：**`_` + 源文件名 + `.zig`**。
- `.yix` / `.yss` 里引用源文件名：`const S = @import("styles.yss");`、`const C = @import("../card/card.yix");`。
  编译器生成双胞胎时把字符串换成双胞胎名（`"_styles.yss.zig"`、`"../card/_card.yix.zig"`），只认 `@import("….yix" / "….yss")`；
  注释、普通字符串、多行字符串、`@embedFile` 里的不动。编辑器里看到、跳转的都是源文件。
- 手写的 `.zig`（`mod.zig` 等）不经过编译器，仍然 import 双胞胎：`@import("_card.yix.zig")`。
- 双胞胎 = 一行文件头 + 编译器原始输出（不格式化，编辑器据此精确映射位置）+ 来源行。
- `zig fmt` 门禁跳过 `_*.yix.zig` / `_*.yss.zig`；`.gitattributes` 标 `linguist-generated`（GitHub 折叠 diff）。

### 1.2 谁来生成

| 时机 | 方式 |
|---|---|
| `zig build …`（本地） | 编译前自动重新生成过期的双胞胎（只写有变化的文件，原子写）；手改或删掉的双胞胎也会被改回来。源文件和双胞胎都没变时这一步直接跳过 |
| `zig build … --watch` | 改 `.yix` / `.yss` 即自动重新生成并重新编译 |
| 编辑器里保存 | yix-lsp 写回双胞胎（当前文本编译不过时不动；同名的手写文件不覆盖） |
| CI（有 `CI` 环境变量；仓库的 CI 另外显式跑 `check-yix`） | 只检查：双胞胎缺失、过期或被手改即失败，不改工作树 |
| 显式 | `zig build gen-yix` 重新生成；`zig build check-yix` 检查（并入 `test-headless`） |

开关 `-Dyix-gen=write|check|off` 覆盖默认（本地 `write`、CI `check`、zenit 作为依赖被构建时 `off`）。
`gen-yix` / `check-yix` 都会报告源文件已删除但生成双胞胎仍残留的情况；恢复源文件或手动移除生成物后再运行，不自动删除文件。
只读环境或 bisect 历史提交时用 `off`。`--watch` 期间新建的 `.yix` 要重启 watch 才会被监听（构建配置阶段登记输入）。

生成范围：`src/ui`、`examples`、`tests/yix`（`build.zig` 的 `yix_source_roots`）。单文件翻译：`zig build yix -- IN OUT.zig`。
依赖 zenit 的项目也可不入库、构建期翻译：`build.zig` 的 `translateYix` 返回缓存里的 `LazyPath`，或取 `zenit_dependency.artifact("yix")` 建同样的 Run step：

```zig
const run = b.addRunArtifact(zenit_dependency.artifact("yix"));
run.addFileArg(b.path("src/page.yix"));
const generated = run.addOutputFileArg("page.zig");
const page = b.createModule(.{ .root_source_file = generated, .target = target });
page.addImport("ui", ui_module);
```

这种方式下生成文件在缓存目录，引用旁边的手写文件（以及 `@import("styles.yss")`）只能改走命名 module；入库的双胞胎没有这个限制。

### 1.3 编辑器

VS Code / Cursor 插件 `editors/vscode-yix`（`zenit-yix`）+ 语言服务器 `zig build yix-lsp`：

- **高亮**：`.yix`（标签、属性、插值、Zig 部分复用 Zig 语法）与 `.yss`（关键字、属性、token、数字、颜色、条件块）。
- **Yix**：Zig 部分的悬停 / 补全 / 跳转 / 引用 / 签名 / 诊断经 ZLS（位置映射往返）；标签名补全（宿主标签 + 本文件组件）；
  属性名补全（宿主元素静态表；组件经 ZLS 查定义后解析 `<Name>Props` 字段与文档注释）；写到一半时在光标后试闭合串修补后照常补全。
- **YSS**：属性 / token（按就近的 theme.json；颜色带色块）/ 枚举值 / 条件 / `when` 的维度与选项 / 插槽 / mixin 补全；属性文档、token 明暗取值、
  配方摘要、mixin 签名悬停；mixin / 维度 / 选项 / 插槽跳转；大纲；照搬的 Zig 与 `{zig}` 值走 ZLS。
- 双胞胎在资源管理器里嵌套到源文件下、只读打开；跳转落到双胞胎时映射回源文件。
- 诊断：Yix / YSS 编译诊断 + ZLS 对生成代码的诊断 + 保存时构建的 Zig 类型错误（ZLS 不做 comptime 语义检查），都指回源文件。

详见 [YIX_EDITOR.md](YIX_EDITOR.md)。

---

## 2. Yix

### 2.1 文件结构

`.yix` 是 **Zig 的超集**：顶层除组件以外的一切（`const` / `fn` / `struct` / `test` / import）原样照搬为 Zig。
组件是返回 `View` 的函数，函数体是声明 + 一个返回模板的 `return`。推荐的组合是 `.yix` 写结构与行为、`.yss` 写样式。
下面这对文件就是 `tests/yix/doc_chip.yix` / `doc_chip.yss`，随 `zig build test-yix` 编译并运行。

```zig
// doc_chip.yix
const ui = @import("ui");
const S = @import("_doc_chip.yss.zig");     // 引用 .yss 的生成双胞胎

pub const Tone = enum { neutral, accent };

/// 可选中的胶囊；传了 onRemove 时显示移除按钮
pub fn Chip(
    label: []const u8 = "",
    tone: Tone = .neutral,
    selected: Model(bool) = false,           // 受控值：调用方传 signal 即双向绑定，不传则组件自持
    onChange: ?Handler(bool) = null,         // 选中状态落地后回调
    onRemove: ?Handler(void) = null,
) View {
    return (
        <row
            style={S.Chip.of(.{ .tone = tone, .selected = selected })}
            focusable
            focusRing
            a11y={.{ .role = .button, .label = label, .selected = selected }}
            onClick={selected = !selected}
        >
            <text style={S.label}>{label}</text>
            {if (onRemove != null)
                <row style={S.remove} a11y={.{ .role = .button, .label = "Remove" }} onClick={onRemove}>
                    <text>×</text>
                </row>
            }
        </row>
    );
}
```

```
// doc_chip.yss
const ui = @import("ui");

recipe Chip {
  base {
    direction: row;
    align-items: center;
    gap: space100;
    padding: space50 space200;
    corner-radius: full;
    background: bg-secondary;
    transition: background 120ms ease-out;
    :hover { background: bg-hover; }
  }
  variant tone = neutral {
    neutral { }
    accent  { background: mix(bg-primary, accent, 0.15); }
  }
  flag selected { border: 1 accent; }
}

style label { color: fg-primary; font-size: sm; }
style remove { padding: 0 space50; corner-radius: full; :hover { background: bg-hover; } }
```

条件可以直接写在模板里（`{if (label.len != 0) …}`），不必先定义 `has_label` 之类的 computed：模板表达式同样做静态提升。

### 2.2 组件

`[pub] fn Name(参数…) View { 声明…; return 模板; }`

| 参数写法 | 含义 |
|---|---|
| `x: T = 默认值` / `x: T` | 数据参数。组件内是 `ui.Source(T)`：调用方可传静态值或响应式源（signal / memo）。不写默认值即**必填**（Zig 编译器强制调用方传） |
| `children: View` / `header: View` | 插槽（见 2.9）：`children` 收标签里的子元素，其它名字是具名插槽。不能有默认值；模板里恰好出现一次 `{名字}`，在 `box` / `row` / `col` / `grid` 里，不能在控制流里 |
| `label: Text = ""` | 字符串参数，并且标签里的文字子元素进它（`<Button>保存</Button>` → label，见 2.4）。一个组件至多一个，不能可选 |
| `x: Model(T) = 初值` / `x: Model(T)` | 受控值（表单组件），见下。不写初值即必填（调用方必须给数据源） |
| `onX: ?Handler(T) = null` / `onX: Handler(T)` | 回调参数。`?Handler` 可选（缺省 null），`Handler` 必填 |

`Handler(T)`、`Model(T)`、`Text` 是内建类型名，写在参数类型的位置、按语法识别（不加 `ui.`；写成 `ui.Handler(…)` 会报错提示）。
组件体里的 `signal(…)` / `computed(…)` / `ref(…)` / `parts(…)` 是内建（按 token 识别，`signal (x)` 同样算），文件顶层不能再声明同名的函数或常量。

**受控值 `Model(T)`**：
- 调用方不传：组件自持，初值即默认值（非受控）。
- 调用方传 signal（模板里 `selected={sig}`）：双向绑定。
- 调用方传 `ui.split(read, write)`：读跟随 `read`，写只交给 `write` 回调，由父组件裁决是否采纳。
- 调用方传**只读**的值（computed、列表行字段 `todo.done`、组件参数）并给了 `onXChange` / `onChange`：即 React 的受控组件——
  组件显示只读值；用户操作以提议值调这个回调，父组件在回调里改数据，显示随之变化；父组件不改（拒绝）或改成别的值（改写）时，
  组件按数据源的实际值恢复 / 修正（与 `ui.split(只读值, 回调)` 同一语义，由 props 归一化自动合成，回调不会再重复调用）。
  例：`{for (todos) |todo| <W.Checkbox checked={todo.done} onChange={toggle(todo.id)} />}`、
  强制大写的输入框 `<W.Input value={shown} onChange={|v| code = upper(v)} />`。只读值而没有回调时，组件只显示、不写。
- 组件内写 `x = …` 是「提议」新值；落地后回调 `on` + 首字母大写的参数名 + `Change`（参数 `value` → `onValueChange`）。
  组件只有一个受控值时也可以用 `onChange`。回调只报落地的值。

- 不支持 `comptime` 参数。
- **参数名与模板属性名只收 camelCase**（`iconOnly`、`testId`；缩写按单词写，`userId` 不是 `userID`），写成 snake_case 在 `.yix` 原文位置报错并给出 camelCase 名。
  生成的 props 结构里是 snake_case 字段（组件内仍按原名用，Zig 侧写 `.icon_only`）。
- `pub fn X` 额外生成 `pub const XProps`（属性补全与外部引用用）。
- 从 Zig 使用：`X(.{ .label = "Save", .on_change = h })`，返回 `View`；可直接作为 `ui.view` 子元素，或 `.mount(scope, cx)` 挂载。
- **生命周期**：组件函数在调用方 scope 下的子 scope 运行，子 scope 绑在根节点上——节点释放时组件建的 signal / memo / effect 一并销毁。
- 组件体只允许声明与一个 `return`；辅助函数写在文件顶层 Zig 里。同名遮蔽暂不支持；`__yix_` 前缀保留给生成代码。

### 2.3 状态

```zig
var count: u32 = signal(0);                 // 可写的响应式状态；类型必须显式写出
var msg: []const u8 = signal("hi");         // 存储按类型选：[]const u8 → 拥有型文本，其它 []const E → 拥有型列表（别名同样生效）
const double = computed(count * 2);         // 派生值（Memo），类型自动推导
```

- `signal` 必须用 `var`、写显式类型；`computed` 必须用 `const`。
- 组件局部里读响应式值必须包在 `computed(...)` 里（不允许局部快照读取）。
- **静态提升**：`computed` 与模板属性表达式只依赖参数时，运行期先求值一次，按响应式图**实际记录到的读取**决定：
  一个依赖都没有（参数此刻全是静态值、也没读外部信号）就收缩成静态值，不建 memo / effect——静态使用的组件零响应式开销；
  读到了信号（包括表达式里函数调用读到的外部 store）就保留为 memo，之后照常跟随。只有 `get()` 算读取，`peek()` 与普通全局变量不算。
  模板里的函数调用即使没有直接引用组件参数，也按调用过程中实际读取的信号跟随；返回响应式源或只能在编译期存储的值时保留原样传递。
- 不能给 `computed` 或只读参数赋值（诊断）。
**挂载句柄与生命周期**：

```zig
const field = ref();                        // 挂载句柄（默认 *ui.Node；组件元素用 ref(ui.view.MountResult)）
effect(total = price * qty);                // 读到的源变化时重跑（读取跟踪依赖）；建好即先执行一次
onMount(measure(field));                    // 根节点挂好后执行一次：此时 ref 已经有节点
onUnmount(log("bye"));                      // 组件卸载时执行
return <box ref={field}>…</box>;
```

- `ref()` 必须用 `const`；模板里 `ref={r}` 挂在元素上，挂载后 `r.get()` 取节点，卸载时清成 null。
- `effect` / `onMount` / `onUnmount` 的参数是事件语句（单条或 `{ a; b; }` 块），规则同 2.8；不收 `|value|`。
  effect 里的读取跟踪依赖（`.get()`），事件处理器里不跟踪（`.peek()`）。effect 归组件 scope，卸载时销毁。
- 组件里不能直接用 `cx` / `scope`（编译报错）：Yix 组件是声明式的。需要挂载时命令式建状态的部分（如 `cx.bindState`），
  写成普通 Zig 组件——`fn mountX(props: P, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node` 加
  `fn X(props: P) ui.view.ComponentOf(mountX) { return ui.view.component(mountX, props); }`——再在模板里当标签用（见 `examples/text_input`）。

### 2.4 模板与元素

模板是**单根**的标签树：`return <col>…</col>;` 或 `return ( … );`。

**宿主元素**

| 标签 | 说明 |
|---|---|
| `box` / `row` / `col` / `grid` | 容器（`row` / `col` 是方向预设的 box；`grid` 对应 `ui.view.grid`） |
| `text` | 文本：只收文字与插值；`box={…}` 给文本节点自身的盒样式（节点自己承载文字，如胶囊徽章） |
| `icon` | `<icon src={ui.icons.x} tint={…} />`：SVG 资源；`src` 可以是 prop，挂载时取值 |
| `image` | `<image src={纹理 id} />`：纹理；同样可 `tint` |
| `canvas` | 自绘：`<canvas draw={f} data={x} animate />`，`f: fn (DrawContext, Data, ui.view.Frame) !void`；数据变化重绘，`animate` 为真时每帧重绘（视口外不画）；无子项 |
| `spacer` | 弹性占位，无属性无子项 |

**宿主属性**（camelCase 写法）

| 属性 | 含义 |
|---|---|
| `style` | 视觉样式：css / cva / sva 部件、样式函数、字面量或它们的元组（见 2.10） |
| `box` | `text` 专用：文本节点自身的盒样式 |
| `testId` | e2e / DevTools 用的 test_id（可为源，挂载时取值） |
| `a11y` | 无障碍属性：字面量的字段可以是源；也可以整体是 `Source(?A11yProps)`（null = 没有语义节点） |
| `onClick` / `onFocus` / `onBlur` / `onHover` / `onLeave` | 事件（见 2.8）。Space / Enter 在焦点节点上合成 click |
| `visible` | bool 或 bool 源：切 display，保留子树与状态 |
| `focusable` | bool 或 bool 源：进出 Tab 序 |
| `focusRing` | 获得键盘焦点时画焦点环 |
| `hitTest` | `false`：不参与命中（点击穿透） |
| `tag` | 语义 tag（`.button` / `.input` …）：命中、a11y 与键盘激活按 tag 区分 |
| `onKeyDown` / `onKeyUp` / `onPointerDown` / `onPointerMove` / `onPointerUp` / `onScroll` | 类型化事件，`\|e\|` 带事件值（见 2.8）；box / row / col / grid / canvas |
| `state` | `.{ .disabled = 源, .invalid = 源, .selected = 源, .expanded = 源 }`：样式条件的状态来源（没写取 a11y 同名字段，见 3.4） |
| `ref` | 挂载句柄（见 2.3） |
| `onEvent` / `eventContext` | 底层通用事件回调与上下文（可为源；调用方挂载后改写过节点上的值就让给后写者）；不能与类型化事件同用 |
| `src` / `tint` | `icon` / `image` |
| `draw` / `data` / `animate` | `canvas` |
| `key` | 只能写在 `{for}` 行的根元素上（见 2.7） |

宿主元素只收表里的属性：写了表外的（给 `<text>` 写 `onKeyDown` 或 `focusable`、给 `<col>` 写 `columns`）在 `.yix` 原文位置报错，
拼写接近的会给出建议（`focusrng` → `focusRing`）。属性表是编译器里的单一来源（`compiler.hostAttrs`），yix-lsp 的补全用同一份，
测试会与 view.zig 的 props 列表逐项比对。

**组件元素**：`<Name … />`、`<W.Card>…</W.Card>`（带命名空间）、`<ui.widgets.Card>`。组件的属性就是它的参数；
以下名字是**根节点属性**（保留名），不进组件参数，由 attrs 包装作用在组件根：
`style` `parts` `testId` `visible` `a11y`，以及类型化事件 `onKeyDown` `onKeyUp` `onPointerDown` `onPointerMove` `onPointerUp` `onScroll`（见 2.8）。
组件自己也声明了这几个名字的参数时编译报错（模板里写 `<X style={…}>` 有歧义，参数也永远传不进去），组件参数要换名字。
例如 Button 的配方覆盖参数叫 `baseStyle`，`style` 留给根节点。其余属性（含 `onClick` / `onChange` 这类组件事件）都是组件参数，组件不声明就是未知属性。

**属性表达式的类型按属性定型**：`variant={if (on) .primary else .ghost}`、`label={if (done) "done" else "todo"}` 这类表达式，
派生值的类型取接收它的组件参数的类型（`ui.view.attrType`），所以枚举字面量、不等长的字符串字面量分支都能直接写；
拿不到参数类型时（组件函数的返回类型依赖参数）退回按表达式本身推导。

**子元素只有文字时**（`<X>文字</X>`）：组件把某个参数声明为 `Text`（内置组件都叫 `label`），文字就进那个参数（`<Button>保存</Button>`）；否则文字照常是子元素。
由 `ui.view.textChild` 按组件的声明（生成的 props 里 `pub const text_child = "label"`）在 comptime 判断，不按参数名猜，与组件名、别名无关。
手写 Zig 组件在 props 结构体里写同样的 `pub const text_child = "label";`。交给它的文字只能是静态字符串（动态文案用 `label={源}`）；同时写了属性和文字子元素会报错。

### 2.5 属性值

| 写法 | 含义 |
|---|---|
| `label="Save"` | 字符串字面量 |
| `count={expr}` | Zig 表达式；除字符串外值都要花括号 |
| `focusRing` | 布尔简写（= `{true}`） |
| `{count}` | 同名简写（= `count={count}`），只能用本地名字 |

- 表达式里引用了响应式值：单独一个名字直接把源传下去；组合表达式生成 memo（可静态提升，见 2.3）；不含响应式值的保持普通值。
  组合表达式里名字代表**值**（读取时跟踪依赖），拿不到源本身——要把源传下去就单独作为一个属性值传；`@TypeOf(n)` 这类类型位置同样是值的类型（不求值、不登记依赖）。
- 匿名结构体字面量照常写：`a11y={.{ .role = .alert, .live = live }}`。

### 2.6 文本与插值

```zig
<text>Count {count}; double {double}</text>
```

相邻的文字与 `{expr}` 合成**一个**格式化文本节点，任一源变化时重排该节点。支持 Unicode 原文。

- **格式说明符**：`{price:.2}`、`{n:>4}`，同 `std.fmt`。
- **字面花括号**：写成插值 `{"{"}` / `{"}"}`（`{{` 不是转义）。
- **空白**（与 JSX 相同）：同一行内的空白原样保留；跨行时，每行去掉行首缩进与行尾空白，非空行之间用一个空格连接，空行丢弃。
  紧挨插值、但与插值不在同一行的文字之间不会自动加空格，需要时写 `{" "}`。
- `text` 里只能放文字与插值（不能嵌标签）。

### 2.7 控制流

控制流写在模板子项位置的花括号里，分支里是一个标签或直接嵌套的控制流。

```zig
{if (expanded) <text>Expanded</text> else if (busy) <Spinner /> else <text>Collapsed</text>}

{switch (tab) { .home => <Home />, .settings => <Settings /> }}       // 枚举，穷尽检查由 Zig 完成

{for (rows) |item| <Row title={item.title} /> else <text>Empty</text>}   // keyed 列表；else = 空列表回退
{for (rows) |item, i| <text>{i}. {item.title}</text>}                    // i 是下标源：行被复用到新位置时跟随更新
{for (options) |opt| <row key={opt.value}>…</row>}                       // 显式 key
{for (0..n) |i| <Star lit={i < score} />}                                 // 按次数展开；n 可来自参数 / 信号
{if (shown) for (rows) |item| <text>{item.title}</text>}                 // 分支里直接嵌套控制流
{if (picked) |name| <text>{name}</text> else <text>none</text>}         // 可选值捕获
{if (parsed) |v| <text>{v}</text> else |e| <text>{@errorName(e)}</text>} // 错误联合：值 / 错误捕获
{switch (shape) { .circle => |r| <text>r {r}</text>, .none => <text>-</text> }}  // 带标签联合的载荷捕获
```

- **分支惰性构造**：每个分支生成为一个函数，分支被选中时才在分支自己的 scope 里构造；分支里的派生值、事件上下文归这个 scope，
  换分支时一并释放。隐藏的分支不建它里面的 memo / effect。
- `if`：支持 else-if 链。`if (x) |v|`：`x` 是可选值或错误联合，`v` 是跟随 `x` 载荷的源——同一分支内载荷变化只更新用到 `v` 的地方，
  不重建分支；`x` 变成 null / 错误时才换到 else。错误联合的 else 可以写 `else |e|` 捕获错误。
- `switch`：对枚举或带标签联合，按标签换分支，穷尽检查由 Zig 完成。联合分支 `.tag => |p|` 捕获载荷（同样是跟随源，同一标签内载荷变化不重建）；
  `else` 分支没有载荷可捕获。
- `for (列表)`：keyed 调和（重排复用行、不重建）。循环变量 `item` 是这一行的**数据源**：同一个 key 的内容变了，不重建行，
  而是写这一行的数据源，行内用到 `item.x` 的地方跟随（**原地更新**：焦点、悬停、局部信号、进行中的过渡都保住）。
  事件里读到的是最新数据。默认 key 是 `item.id`；没有 `id` 字段或要自定义时在行根元素写 `key={…}`
  （只能引用循环变量，按内容深度哈希）。行能捕获外层的源。
- `for (0..n)`：区间从 0 开始；`n` 静态时一次展开，会变时整体重建（行没有身份）；负数钳到 0；不能带 `else`。
- 分支里直接嵌套的 `for` 后面不能接 `else`（与外层 `if` 的 else 有歧义，诊断）；要两个分支就写两个 `{if}`。

### 2.8 事件

事件属性的值是**语句**，在事件发生时执行；整个处理器自动合批（多次写入只触发一次更新）。

| 写法 | 含义 |
|---|---|
| `onClick={count += 1}` | 信号赋值：`=` `+=` `-=` `*=` `/=`；处理器里读值是 `.peek()`（不跟踪） |
| `onClick={{ a += 1; b += 2; }}` | 多条语句：写成块（外层花括号是属性值，内层是 Zig 块）。单层花括号里只能有一条语句 |
| `onClick={if (!locked) { n += 1; if (n > 2) n = 0; } else n = -1}` | `if` / `else`（可嵌套、可带块）；语句里的 `if` 表达式必须有 `else` |
| `onClick={save()}` | 调用函数 |
| `onClick={onClose}` | 转发回调参数（可选回调为 null 时不做事） |
| `onClick={if (!disabled) onPress}` | 门控后转发 |
| `onClick={onPick(7)}` | 带一个值调用回调（必须是整条语句） |
| `onChange={\|v\| n = v}` | 捕获组件事件的值 |
| `onKeyDown={\|e\| if (e.key == .escape) { close(); e.consume(); }}` | 宿主元素的类型化事件（见下） |
| `onClick={{ const v = try parse(text); n = v; }}` | `const` 局部与 `try`：失败经 `ui.on.reportError` 上报，后面的语句不执行 |
| `<Toggle on={flag} />`（`on: Model(bool)`） | 受控绑定：组件内 `on = !on` 提议新值 |

- 写入后再读拿到的是新值（`a = 1; b = a + 1` 里 `b` 用的是 1）。
- `onClick={save}` 与 `onClick={save()}` 一样，都是**调用**（不是传函数引用）。
- `onClick={ui.on.set(n, 1)}` / `ui.on.toggle(…)`：现成的处理器原样传（实参不经响应式改写，传的是源本身）。
- **组件元素上以 `on` 开头的属性按接收参数的类型分流**，不按名字猜：参数是 `Handler(T)` 才是事件；`onTop: bool` 这类数据参数按值传。
  事件语句（赋值、调用、`if`、块、`|v|`）只能给事件参数，字面量（`true`、`3`、`.x`）只能给数据参数，写反了在 Zig 编译期报错（定位回 `.yix`）；
  单个名字 / 字段（`{save}`、`{flag}`）按参数类型取一种含义。宿主元素的事件属性是固定的一张表，没有歧义。
- `if (a) x = 1; else y = 2` 不是合法 Zig（`else` 前不能有分号），报错并提示写成 `if (a) x = 1 else y = 2` 或带块的形式。
- `const` 局部只在后面的语句里可见，不能遮蔽组件里的名字；不能 `var`、`for`、`while`、`switch`。

**宿主元素的类型化事件**（`box` / `row` / `col` / `grid` / `canvas`）：

| 属性 | `\|e\|` 的类型 | 说明 |
|---|---|---|
| `onKeyDown` / `onKeyUp` | `ui.view.KeyPress` | `key` / `modifiers` / `raw_keycode`；只发给焦点所在的元素及其祖先 |
| `onPointerDown` / `onPointerMove` / `onPointerUp` | `ui.view.Pointer` | `x` / `y` 是元素内坐标，`window_x` / `window_y` 窗口坐标，`button` / `modifiers`，move 带 `dx` / `dy` |
| `onScroll` | `ui.view.Scroll` | `dx` / `dy` / `phase` / `momentum` / 坐标 |

处理器默认不拦截事件：`e.consume()` 阻止默认行为（Tab 切焦点、空格 / 回车合成点击、滚动容器滚动），`e.stop()` 再停止向祖先传播。
事件沿父链冒泡，子元素上发生的事件祖先也会收到。这几个属性与底层的 `onEvent` 不能用在同一个元素上。

**组件元素上的类型化事件**（`<W.Input onKeyDown={…} />`）：挂在组件根的捕获槽，先于组件自己的处理——焦点在组件根或它内部时都先到这里；
`e.consume()` / `e.stop()` 让这个事件到此为止：组件不再处理（例如拦下 Input 对某个键的默认处理），组件外层的祖先也不再收到；
不调用则组件照常处理。焦点、点击合成不受影响（按命中决定，不看处理器的返回）。
不占用组件根自己的 `onEvent`；组件根已经有捕获处理器时挂载失败。

未实现：字段写入、表达式内新建绑定。

### 2.9 子元素插槽

```zig
pub fn Panel(title: []const u8 = "", children: View) View {
    return <col><text>{title}</text><col>{children}</col></col>;
}
// 使用：<Panel title="Settings"><text>value {n}</text><Button onClick={n += 1}>More</Button></Panel>

pub fn Frame(header: View, children: View, footer: View) View {
    return (
        <col>
            <row>{header}<text>…</text></row>
            <col>{children}<text>always last</text></col>
            {footer}
        </col>
    );
}
// 使用：<Frame header={<text>Title</text>} footer={<Button onClick={save()}>Save</Button>}><text>body</text></Frame>
// Zig：ui.view.with(Frame(.{}), .{ body }).slots(.{ .header = …, .footer = … })
```

- 标签里的子元素进 `children`；组件元素上**值是元素**的属性（`header={<…/>}`，只能是一个元素）进同名的具名插槽。
- `{名字}` 可以在容器的任意位置：在末尾时子元素追加到容器末尾；在中间时那里放一个锚点（不占位、不计 gap、不进命中与 a11y），子元素插在它前面。
- 插槽里的内容归**调用方**的 scope（读写调用方的信号），挂在组件提供的位置上。最多 4 个具名插槽。
- 未实现：片段（组件返回多个根），见 §6。

### 2.10 样式接入

`style={…}` 收下列任意一种，或它们的元组 `.{ a, b }`（后者覆盖前者）：

| 写法 | 说明 |
|---|---|
| `S.title` | `ui.css(...)` 样式对象（YSS 的 `style`） |
| `S.Card.of(.{ .kind = v, .selected = sel })` | `ui.cva` 配方（YSS 的 `recipe`），维度值可以是源 |
| `S.Tag.slot(.root, .{ … })` | `ui.sva` 插槽配方的某个插槽 |
| `p.root`（`const p = parts(S.Tag, .{ … });`） | 插槽配方一次解析：一组维度值驱动全部插槽，漏传维度编译报错（组件体里声明） |
| `S.name.of(.{ .p = 源 })` | YSS 参数化样式（尺寸、间距、颜色覆盖等随参数变化的值，见 YSS.md） |
| `ui.view.styleBy(源, f)` | 逃生口：`f(值, tokens) BoxStyle`，只有 Zig 才算得出来的样式 |
| `ui.view.statesBy(源, f)` | 运行期才知道的条件层：`f` 返回 ConditionalStyle，悬停 / 按下由节点状态叠加 |
| `ui.view.loop(.{ .period_ms, .on }, f)` | 随时间循环：样式 = f(相位, tokens)，墙钟相位，视口外不推进 |
| `.{ .gap = .space200 }` | 内联字面量 |

- 组件用 `parts={…}` 给内部部件传样式。
- token 引用在应用时取值，换主题自动重放；静态样式不建 effect（挂节点的主题重放槽）。
- 过渡：样式对象里 `.transition = ui.transition("background 150ms ease-out")`（YSS 里直接写 `transition: …;`）。
- 条件的状态来源（普通宿主元素上）：
  - `_hover`（YSS `:hover`）、`_active`（`:active`，按下且指针仍在节点内）、`_focus`（`:focus`）、`_focus_visible`（`:focus-visible`，
    键盘等非点击方式获得的焦点）由节点自己驱动；
  - `_disabled` / `_invalid` / `_selected` / `_expanded` 取元素的 `state={.{ .disabled = 源, … }}`，没写就取 `a11y` 的同名字段；
    样式用了某个条件、两处都没有时编译报错；
  - 只为配方实际用到的条件接线；状态只看节点自己，不向后代传播。业务状态（选中项、种类）仍推荐写成 cva / sva 的变体。
- 条件层的优先级是固定的：**base ← selected ← expanded ← hover ← active ← focus ← focus-visible ← invalid**，`disabled` 短路其余一切；
  与书写顺序无关。
- 文本：唯一的条件是 `:hover`（文本节点自己的悬停）；用在 `<text>` 上的 css 样式可以同时写盒属性（落到文本节点自身，同 `box=`），
  不能放进元组，`v.when` 里只能切换文字字段。
- 依赖数据的样式用参数化样式（`S.name.of`）或 cva / sva 的变体，`styleBy` 是逃生口；每个节点只能有一个 `ui.view.loop`。
- 图标着色：随样式变体 / 条件走写 YSS 的 `icon-color`；跟随任意数据写 `tint={ui.view.tintBy(源, f)}`。两者不能用在同一个元素上（编译报错）。

### 2.11 编译期诊断（节选）

诊断指向 `.yix` 的源位置（CLI 打印 `路径:行:列: error: …`，编辑器里实时显示）：

- 结构：`a View component returns one root tag`；`closing tag does not match opening tag`；`unknown host tag …`；
  `text accepts text and interpolation only`；`spacer takes no attributes or children`。
- 状态：`signal declarations require an explicit value type`；`signal declarations must use var`；
  `computed declarations must use const`；`reactive reads in component locals require computed(...)`；
  `cannot assign to a computed value or read-only prop`。
- 参数：`component parameters require a type`；`component parameter names are camelCase: write …`；
  `write the built-in parameter type as Handler(T) (without ui.)`；`a Model parameter cannot be optional`；`the only View parameter is children`。
- 属性：`attribute names are camelCase: write …`；`<tag> has no attribute …`；`label is given both as an attribute and as text children`。
- 组件体：`` `cx` / `scope` is not available in a Yix component …``。
- 插槽：`component declares header: View but the template has no {header}`；`{children} appears more than once`；`{children} (a slot) cannot be inside control flow`；
  `element values only go on component attributes (named slots)`；`the value of … must be a single element`。
- 列表：`a row key may only use the loop variable`；`key={…} only goes on the root element of a {for} row`；
  `loop ranges start at 0`；`for (0..n) takes no else branch`。
- 事件：`events support function calls, simple signal assignments and if / else`；`an if expression in an event statement needs an else`；
  `a callback takes at most one value`；`events on host elements carry no value; |v| works on component events`；
  `several event statements go in a block: onClick={{ a; b; }}`；`` `; else` is not valid Zig …``。
- 元素：`canvas requires draw=…`；`icon / image require src=…`；`icon / image take no children`。
- 控制流：`else |err| needs if (x) |v| on an error union`；`the else branch of a switch has no payload to capture`。
- 尚未实现的写法：`shadowed local names are not supported yet`；
  `comptime component parameters are not implemented`；`expression-local bindings and captures are not implemented`。

Zig 层面的类型错误（属性名拼错、类型不符等）由 `zig build` 报出，指向双胞胎或接收属性的库代码（如 `props.zig`）。换算回源文件：

- 命令行：`zig build 2>&1 | zig-out/bin/yix map-errors`——双胞胎里的位置换成 `.yix` / `.yss` 的行列（原位置留在行尾）；
  位置在库代码里的错误，按引用链里的组件体帧（调用方写模板的地方）补一行 `.yix` 位置的 note。
- 编辑器：yix-lsp 保存时在工作区根目录跑构建，同样换算后作为 `zig build` 来源的诊断显示在 `.yix` / `.yss` 上（见 [YIX_EDITOR.md](YIX_EDITOR.md)）。

双胞胎里模板一个元素一行、按嵌套缩进，派生值单独成块，所以报错行能对应到源里的一个元素或一个表达式。

### 2.12 成本模型

Yix 生成的是普通 Zig，但有几处分配与运行期工作在源码里看不见，列在这里：

| 写法 | 运行期成本 |
|---|---|
| `var x: T = signal(v)` | 一个 signal（组件 scope 分配，组件卸载时释放） |
| `computed(…)` / 模板里依赖响应式源的表达式 | 依赖此刻全是静态值时直接求值、**不建 memo**；否则一个 memo（首帧多一次求值，用来判定静态与否） |
| 事件属性（`onClick={…}`） | 一个处理器：捕获的名字拷进 scope 里的上下文（一次分配） |
| `effect(…)` | 一个 effect（建好先执行一次） |
| `{if …}` / `{switch …}` 的分支 | 分支惰性构造：选中时在分支自己的子 scope 里建，切走时整块释放；源静态时没有分支开销 |
| `{for …}` 的每一行 | 一个子 scope；按 key 调和，同 key 的行原地更新 |
| `style={…}` 里有响应式部件 / 参数化样式的参数是源 | 一个 effect 重算并增量应用；全部静态时只随主题重放、不建 effect |
| `ui.view.loop` | 开着时每帧按相位重算（视口外不推进） |

没有隐藏的控制流：事件里的 `try` 失败经 `ui.on.reportError` 上报（不中断别的处理器），其余错误照常经 `try` 冒到挂载调用方。

### 2.13 已知限制

- 单根：组件只能返回一个根节点（没有片段）。
- 未实现：片段（多根）、局部组件、render prop、comptime 参数、事件字段写入、
  按子项位置出样式（`:first-child` 类）、canvas 的命中形状由绘制给出。
- **数据的判等与所有权**：
  - `Signal.set` 按**内容**判等（切片逐元素、字符串逐字节、结构体逐字段）：内容相同的新数组不会通知，换了地址但内容不变的借用字符串也不会。
    列表的 key 命中后同样按内容判断这一行要不要更新。
  - 谁持有字符串：Yix 里声明的 `var msg: []const u8 = signal(…)` 与 `var xs: []const T = signal(…)` 是**拥有型**（写入时复制，调用方的缓冲可以随即释放）；
    `[]const u8` 参数、经 `scope.createSignal` 建的信号、列表里每一项的字符串字段是**借用**的切片，调用方要保证它比读它的节点活得久。
  - 推荐：列表数据放在拥有型列表信号或长期存在的数组里（例如 store 持有的 `std.ArrayList`），换数据时整体 `set` 新的切片；
    不要原地改写数组元素后再 `set` 同一个切片（内容判等看到的已经是新内容，旧值没有留存，比较结果是「没变」）。

---

## 3. YSS

### 3.1 文件结构

`.yss` 顶层的 `recipe` / `style` / `mixin` 是样式 DSL，其余照搬为 Zig（import、依赖数据的样式函数）。文件里要有
`const ui = @import(...)`（生成代码引用 `ui.cva` 等）。组件的样式文件约定叫 `styles.yss`。

```
const ui = @import("../../ui.zig");

/// 卡片根：选中时 2px accent 边框且不显示悬停高亮
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

/// 依赖参数的值：参数化样式（视图里 S.size.of(.{ .width = width, .height = height })）
style size($width: ?f32, $height: ?f32) { width: $width ?? fit; height: $height ?? fit; }
```

### 3.2 声明

| 写法 | 生成 |
|---|---|
| `style name { … }` | `pub const name = ui.css(.{ … });` |
| `recipe Name { … }` | `pub const Name = ui.cva(.{ … });` |
| `recipe Name slots(a, b) { … }` | `pub const Name = ui.sva(.{ .slots = .{ .a, .b }, … });`，各块里按插槽分 `a { … }` |
| `mixin name(p, q) { … }` | 不生成代码；`name(x, y);` 在调用处展开，参数按名字替换（声明顺序不限，禁止递归） |

声明前的 `///` 文档注释保留到生成代码（mixin 的随之去掉）。`pub` 前缀可写可不写（配方本来就生成 `pub const`）。

### 3.3 配方的段

| 段 | 含义 |
|---|---|
| `base { … }` | 始终应用 |
| `variant dim = 默认 { opt { … } … }` | 变体维度；不写默认取第一个选项。维度名不能与关键字（base / variant / flag / when / in）同名，按含义起名（`variant kind`） |
| `flag dim { … }` / `flag dim { … } else { … }` / `flag dim;` / `flag dim = true { … }` | 布尔维度：块是开着时的样式，`else` 块是关着时的样式（不写为空）；`flag dim;` 只用于复合条件。单个 flag 的两态用 `else`，多个维度组合用 `when` |
| `when 条件 { … }` | 复合规则；条件 `a & !b & c = x & d in (y, z)`，`in` 展开成多条规则 |

合并顺序：base < variants（多个维度按声明顺序，flag 的 `else` 块在它自己的位置）< when（与 `ui.cva` 一致）。

**命名**：配方 PascalCase（生成的是类型）；样式、插槽、维度 snake_case（`close_icon`），不加 `Style` 后缀——编译器检查。
维度按含义起名：组件参数叫 `variant` 时维度叫 `kind`（`variant variant` 读起来像语法错误，编译器拒绝）。

**两种 `when`**：配方的 `when a & !b & c = x` 引用的是**维度**（不带 `$`），展开成 cva 复合规则，按条件匹配后叠加；
参数化样式的 `when $flag & $e = x & {zig}` 引用的是**参数**（带 `$`），可以写 `{zig}` 条件，按书写顺序叠在 base 上。

### 3.4 块的内容

- `属性: 值;`
- 条件块：`:hover` `:active` `:focus` `:focus-visible` `:selected` `:expanded` `:invalid` `:disabled`（插槽配方里写在插槽块内）。
  用在**普通元素**上时的状态来源：`:hover` / `:active` / `:focus` / `:focus-visible` 由节点自己驱动（`:focus-visible` 是键盘等非点击方式获得的焦点）；
  `:disabled` / `:invalid` / `:selected` / `:expanded` 取元素的 `state={.{ .disabled = 源 }}`，没写就取 `a11y` 的同名字段，
  两处都没有时编译报错。状态只看节点自己，不向后代传播；只为配方实际用到的条件接线。
- mixin 调用：`tone(accent);`
- 插槽块（插槽配方的 base / 选项 / when 第一层）：`root { … }`。
- 同一块里**属性**后写覆盖先写（mixin 展开后再写同名属性即覆盖）。条件块之间不按书写顺序，按固定优先级叠加
  （base ← selected ← expanded ← hover ← active ← focus ← focus-visible ← invalid，disabled 短路，见 2.10）。

### 3.5 属性与值

- **属性名**是 `BoxStyle` / `TextStyle` 的字段名的连字符写法：`corner-radius` → `.corner_radius`、`font-size`、`align-items`……
  `color` 与 `text-color` 互为别名；另有 `typography`（排版 token，一次给字号 / 字重 / 行高，单项属性覆盖它）与 `transition`。
- **写错属性名或枚举值是编译错误**，报在原文位置，属性名带拼写建议（`corner-radus` → `did you mean corner-radius?`）；
  属性表与枚举值从 ui 的样式类型反射生成（`src/yix/style_schema_generated.zig`，`zig build gen-yss-schema`，
  `check-yss-schema` 并入 test-headless）。
- **数字** = 像素 / 原值：`12`、`0.5`、`.5`、`-2`、`12px`。
- **名字** = token 或枚举：
  - token 属性（颜色、间距、圆角、字号、字重、行高、边框宽、尺寸、阴影、透明度、`typography`）的名字按 theme.json 查：
    先按原名精确匹配，找不到再把 `-` 换成 `_`。所以 `bg-primary` 对上 `bg_primary`，主题里的 `text-hairline`、`2xl` 也能直接写。
    写错由 Zig 编译期查表报出并列出可选名。嵌套分组里的 token（`tokens.color.blue.300`）不能直接引用，经语义 token 用。
  - 枚举属性（`direction`、`align-items` …）的名字是框架枚举值，连字符转下划线：`row-reverse` → `.row_reverse`。
  - 宽高的 `grow` / `fit` / `fill`。
  - 映射关系与示例见 [STYLING.md](STYLING.md) 的 token 类别表；用哪份 theme.json 取决于编译该文件的模块（`src/ui` 用
    `src/tokens/default.json`，examples 用 `examples/theme.json`）。
- 颜色：`transparent`；`#rrggbb` / `#rrggbbaa`；`rgb(r, g, b)` / `rgba(r, g, b, a)`（通道 0..255，alpha 0..1 同 CSS）；
  `mix(a, b, 权重)`（颜色混合，权重 0..1，操作数是颜色 token 或颜色值，换主题跟随）；
  `{zig 表达式}` 原样嵌入（逃生口）：它进的是 `ui.css` 的字面量，**必须是编译期常量**；依赖运行期数据的值写参数化样式（那里的 `{zig}` 可以引用参数）。
- **简写**：`padding` / `margin` 收 1 / 2（竖 横）/ 4（上 右 下 左）个值；`border: 宽 [颜色]`；
  `shadow: md`（token）或 `shadow: x y blur [spread] 颜色`（颜色可为 token / 颜色值 / mix），多层逗号分隔（`shadow: lg, 0 32 80 #00000019`）；
  `transition: …` 整段原文是过渡描述（只能是纯文本），时长可以写 `200ms` / `0.2s` 或设计系统的 duration token（`fast` / `normal` / `slow`，
  编译期按选定设计系统取值），时长与缓动之外的词编译报错。
- `icon-color`：图标着色（icon / image 的 tint），随变体 / 条件走，替代按变体手写的 tint 映射。
- **用在 `<text>` 上的 style**：一个 `style` 可以同时写文字属性与盒属性（`padding` / `background` / `corner-radius`…），文字部分进文本样式、
  盒部分落到文本节点自身（等同 `box=`），不再需要拆成两个样式；它必须是整个 style（不能放进元组），条件块里只能改文字属性；
  文字唯一的条件是 `:hover`（文本节点自己的悬停，例如链接悬停色）。配方（recipe）的文字插槽仍只收文字属性。
- 不做：`:group-hover`（目前只有 Radio 一个用户，用组件里的悬停信号）、`:first` / `:last`。

### 3.6 诊断（节选）

`unknown recipe section`；`properties go inside a slot block`；`not a slot of this recipe`；`unknown condition`；
`not a declared variant or flag`；`applies to flags`；`is a flag: write x or !x`；`not an option of`；`declared twice`；
`unknown mixin`；`takes N argument(s)`；`nested too deeply (recursive mixin?)`；`takes 1, 2 or 4 values`；`empty transition`；
`a transition is plain text`；`is not a style property (did you mean …?)`；`is not a value of …`；`malformed number`；
`mix weight must be within 0..1`；`colors are #rrggbb or #rrggbbaa`；`rgba: alpha is 0..1`；`` `shadow` is a token or `x y blur [spread] color` ``；`empty {} expression`；`must be a Zig identifier`；`is a Zig keyword`（选项名除外：`error` 这类选项生成 `.@"error"`）；
`has the same name as a YSS keyword`（维度名不能叫 base / variant / flag / when / in）。过渡里时长与缓动之外的词在 Zig 编译期报错。

### 3.7 限制

- 依赖运行期数据的连续映射写参数化样式 `style name($p: T) { … }`（见 YSS.md），Zig 才算得出来的写 Zig 函数配 `ui.view.styleBy`。
- 插槽块不能嵌套（`.yss` 编译诊断）；条件块不能嵌套，但目前要到 Zig 编译期才由 `ui.css` 报错，`.yss` 编译器不拦。
- token 名的静态检查在 Zig 编译期：生成的双胞胎在属性那一行按名字取引用（`ui.tokenRef`），拼错的 token 名经映射直接报在 `.yss` 的属性行。LSP 的 token 补全与悬停按**就近的 theme.json**（从文件所在目录往上找；examples 下用
  `examples/theme.json`），找不到时用默认设计系统（`src/tokens/default.json`）；theme.json 改了会自动重新读取。

---

## 4. 概念对照

| React | SwiftUI | Svelte 5 | Yix |
|---|---|---|---|
| `function C(props)` + JSX | `struct C: View` | `.svelte` 组件 | `pub fn C(…) View { return <…/>; }` |
| `useState` | `@State` | `$state` | `var x: T = signal(v);` |
| `useMemo` | 计算属性 | `$derived` | `const y = computed(expr);`（自动跟踪，无依赖数组） |
| 受控 `value` + `onChange` | `@Binding` | `bind:value` | `x: Model(T) = 初值` + `onXChange` |
| `props.children` | `@ViewBuilder content` | `{@render children()}` | `children: View` + `{children}`；具名插槽 `header: View` + 调用方 `header={<…/>}` |
| `cond && <A/>` / 三元 | `if` | `{#if}` | `{if (c) <A/> else <B/>}` |
| `list.map(x => <Row key=…/>)` | `ForEach` | `{#each … (key)}` | `{for (xs) \|x, i\| <Row key={…}/>}` |
| `onClick={() => setN(n + 1)}` | `Button { n += 1 }` | `onclick={() => n++}` | `onClick={n += 1}` |
| CSS-in-JS / Tailwind 变体 | `ViewModifier` | `<style>` | `.yss` 的 `recipe` / `variant` / `flag` |
| `useEffect` / `ref` | `.onAppear` / `@FocusState` | `$effect` / `bind:this` | `effect(…)` / `onMount(…)` / `onUnmount(…)`；`const r = ref();` + `ref={r}` |

**常见写法**

- 表单控件：参数用 `Model(T)`，事件里写 `x = 新值`，调用方 `<Switch checked={on} />` 即双向绑定。
- 带选中态的列表：`{for (items) |item| <Row key={item.id} selected={item.id == current} onClick={current = item.id} />}`。
- 条件样式：数据驱动的状态写成 YSS 的 `variant` / `flag`，模板里 `S.X.of(.{ .kind = kind, .on = on })`；交互态用 `:hover` / `:active` / `:focus-visible`，元素状态用 `:disabled` 等（来源见 3.4）。

## 5. 速查

```zig
// ── Yix ──
pub fn Name(x: T = d, req: T, children: View, header: View, v: Model(T) = d, onX: ?Handler(T) = null, onY: Handler(T)) View
var s: T = signal(init);          const c = computed(expr);          const p = parts(S.Tag, .{ .color = c });
const r = ref();   effect(stmt);   onMount(stmt);   onUnmount(stmt);
<box|row|col|grid|text|icon|image|canvas|spacer …/>     <Comp …/>   <W.Card>…</W.Card>
attr="s"   attr={expr}   flag   {name}   key={…}   ref={r}   state={.{ .disabled = d }}   header={<text>…</text>}
{if (c) <A/> else if (d) <B/> else <C/>}   {if (opt) |v| <A/> else <B/>}   {if (res) |v| <A/> else |e| <B/>}
{switch (e) { .a => <A/>, .b => |payload| <B/> }}
{for (xs) |x, i| <Row/> else <Empty/>}（x 是行数据源，同 key 原地更新）   {for (0..n) |i| <Dot/>}
<col>{header}<text/>{children}<text/></col>（插槽可在任意位置）
onClick={n += 1}  {{ const v = try f(); a = v; }}  {if (c) s else t}  {save()}  {onPress}  {onPick(7)}  {|v| n = v}
onKeyDown={|e| if (e.key == .escape) { close(); e.consume(); }}   onPointerDown={|e| x = e.x}   onScroll={|e| e.stop()}
style={.{ S.a, S.R.of(.{ .k = v }), p.root, ui.view.styleBy(src, f) }}

// ── YSS ──
style name { prop: value; :hover { … } :focus-visible { … } :disabled { … } }
recipe Name [slots(a, b)] { base { … } variant d = x { x { … } } flag f [= true] [{ … } | ;] when f & d in (x, y) { … } }
mixin m(p) { … }      m(arg);
style name($p: T = d, $q: ?T) { prop: $p; prop: $q ?? value; prop: {f($p)}; when $flag & $e in (x, y) & {$p > 0} { … } }   // 视图：S.name.of(.{ .p = 源 })
值：12  .5  12px  bg-primary  column  grow  transparent  #rrggbb  #rrggbbaa  rgba(0, 0, 0, 0.5)  mix(a, b, 0.25)  {zig}
简写：padding: 1 | 1 2 | 1 2 3 4;   border: 1 accent;   shadow: md | 0 4 12 [spread] accent | lg, 0 32 80 #00000019;   icon-color: fg-secondary;
      transition: background 150ms ease-out | background fast ease-out;
```

---
