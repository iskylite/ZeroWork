# Yix 编辑器支持

LSP 代理 + 仓库内固定版本 ZLS + VS Code 扩展。语言本身见 [YIX_REFERENCE.md](YIX_REFERENCE.md)。

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| 位置映射 | `src/yix/compiler.zig` 的 `compileMapped` | 照抄进生成代码的源（文件级 Zig、表达式每个 token、原样属性值、局部声明、参数类型 / 默认值、组件标签名、事件赋值目标）记成逐字节段；合成代码（camelCase 属性名 → snake 字段）记成指向源点的段。诊断偏移一律是原文件绝对偏移 |
| 语言服务器 | `tools/yix_lsp.zig`（`zig build yix-lsp` → `zig-out/bin/yix-lsp`） | 每个 .yix / .yss 以磁盘上的双胞胎 `_<文件名>.zig` 为虚拟文档（内容是当前文本的编译结果，didOpen / didChange 给 ZLS 子进程；它本来就在构建图里，命名模块 `@import("ui")` 也能解析）；保存时把双胞胎写回磁盘（编译不过不动）。悬停 / 补全 / 跳转 / 类型跳转 / 实现 / 引用 / 高亮 / 签名：位置映射过去转发 ZLS，结果映射回来。诊断 = Yix 编译诊断 + ZLS 对虚拟文档的诊断（映射回 .yix）。.yss 同样编译成虚拟文档：照搬的 Zig 与 `{zig}` 值走 ZLS，DSL 部分（属性 / token / 条件 / mixin / 变体）的补全、悬停、跳转、大纲由代理按样式编译器的大纲与 schema 直接回答（见 [YSS.md](YSS.md#编辑器)）。ZLS 结果落在双胞胎上时按源文件的编译段表映射回源文件 |
| VS Code 扩展 | `editors/vscode-yix`（`npx @vscode/vsce package` → `.vsix`） | 语言 `yix` 与 `yss`（单词含 `-`）、双胞胎在资源管理器里嵌套到源文件下并只读打开、TextMate 语法（Zig 部分复用 `source.zig`）、拉起 yix-lsp；ZLS 依次取 `yix.zls.path`、有效的 `zig.zls.path`、工作区 `zig-out/bin/zenit-zls`、PATH 的 `zenit-zls` / `zls`、Zig 扩展下载的那份 |

## 使用

先确认 `zig version` 为 **0.17.0**。以下命令在仓库根目录执行。
macOS shell 打包安装：

```sh
zig build dev-tools
(cd editors/vscode-yix && npm ci && npx @vscode/vsce package --out zenit-yix.vsix)
code --install-extension editors/vscode-yix/zenit-yix.vsix
```

Windows PowerShell：

```powershell
zig build dev-tools
if ($LASTEXITCODE -ne 0) { throw 'Development tools build failed' }
Push-Location editors/vscode-yix
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
    npx @vscode/vsce package --out zenit-yix.vsix
    if ($LASTEXITCODE -ne 0) { throw 'Extension packaging failed' }
} finally { Pop-Location }
code --install-extension .\editors\vscode-yix\zenit-yix.vsix
```

打开仓库根目录，`yix-lsp` 默认在 `zig-out/bin/yix-lsp`；Windows 自动查找
`yix-lsp.exe` 和 `zenit-zls.exe`。`zig build yix-lsp` 同样安装两个工具，
`zig build zls` 只安装 `zenit-zls`。Node/npm 仅用于扩展打包，不是 GUI 运行依赖。
Cursor 等 VS Code 衍生编辑器使用自己的 install-extension 命令安装相同 VSIX。

在其他消费项目中，工作区可能没有这两个工具，可在 VS Code workspace 设置中给绝对路径：

```json
{
  "yix.lsp.path": "C:/work/zenit/zig-out/bin/yix-lsp.exe",
  "yix.zls.path": "C:/work/zenit/zig-out/bin/zenit-zls.exe",
  "zig.zls.path": "C:/work/zenit/zig-out/bin/zenit-zls.exe",
  "yix.buildOnSave": ["zig", "build", "windows-arm64-storybook", "-Dwindows-arch=x86_64", "-Dgpu-backend=d3d12", "-Doptimize=fast"]
}
```

路径需要替换为本机 checkout。上述保存命令用于 **Zenit 仓库自身**；消费项目应改为
自己项目的构建命令。macOS 开发可用 `["zig", "build", "hello-button"]`。
编辑器进程的 PATH 也必须能找到 Zig 0.17.0。跨编译的 GUI 在 Windows 运行，LSP
仍在本机运行；不能把 Mac 上的 `yix-lsp` 二进制复制到 Windows 当 `.exe` 使用。

组件与样式的入门示例见 [YIX_YSS_GUIDE.md](YIX_YSS_GUIDE.md)。

### Zig 0.17 的 ZLS 配置

兼容版本随本分支放在 `vendor/zls`，其他开发者检出仓库后用 Zig **0.17.0** 构建即可；
无需额外检出 ZLS 仓库。固定来源是 `zigtools/zls` master
`eab2be0fd74443a27662da809b771c4ad0d2afcf`，以及保留作者信息的
[PR #3270](https://github.com/zigtools/zls/pull/3270) commit
`9b57f17367e2a11ddb6af0efcbe992c82709d165`，再加本仓库的容量、诊断恢复、资源清理和依赖解析修复。
来源与限制见 [vendor/zls/ZIG017.md](../vendor/zls/ZIG017.md)。

扩展会自动选用工作区 `zig-out/bin/zenit-zls`。显式设置 `yix.zls.path` 或有效的
`zig.zls.path` 仍优先；普通 Zig 编辑器也可将 ZLS 可执行文件配置为该二进制的绝对路径。
VS Code 的 Zig 扩展使用 `zig.zls.path`；Windows 路径以 `zenit-zls.exe` 结尾。
命令行验收可显式指定：

```sh
zig build dev-tools
YIX_ZLS="$PWD/zig-out/bin/zenit-zls" \
  python3 tests/yix/lsp/smoke.py zig-out/bin/yix-lsp
```

ZLS 异步加载实际构建模块图；验收在有限时间内重试真实悬停断言，等不到正确结果仍会失败。
Zig 0.17 协议尚未包含不被 compile/check/test 步骤引用的导出模块：仅 `addModule` 的库项目
需要添加正常 check 步骤。仅被构建脚本使用、未出现在序列化模块或步骤图中的依赖、
含点的依赖别名和 install-prefix 相对路径仍有限制。上游进展见
[ZLS #3208](https://github.com/zigtools/zls/issues/3208)。

### 保存时构建（Zig 类型错误显示在 .yix 上）

ZLS 不做 comptime 语义检查，属性名拼错、类型不符这类错误只有 `zig build` 才报，而且指向双胞胎或库代码。
yix-lsp 在保存 `.yix` / `.yss` 后在工作区根目录跑一次构建（后台线程；构建中又保存就在结束后再跑一轮），
把报错按段表换算回源文件（`src/yix/errmap.zig`：双胞胎里的位置直接映射；库代码里的位置按引用链里的组件体帧映射），
作为来源 `zig build` 的诊断发布；改动后这些诊断先撤下，下次保存再算。

- 命令：VS Code 设置 `yix.buildOnSave`（字符串数组，例如 `["zig", "build", "test-yix"]`；`[]` 关闭）；
  其他编辑器用 initializationOptions `buildOnSave` 或环境变量 `YIX_BUILD_ON_SAVE`（空格分隔，`off` 关闭）。
  都没设时，工作区根目录有 `build.zig` 就跑 `zig build`。
- 命令行同样的换算：`zig build 2>&1 | zig-out/bin/yix map-errors`；Windows 使用 `zig-out/bin/yix.exe`。流水线最终退出状态不等于构建退出状态，CI 应另外检查构建是否成功。

## 验证

- `zig build test-yix`：段表性质（逐字节段与源一致、12+ 标识符跨上下文往返、诊断绝对偏移）与 yix-lsp 的位置换算单测。
- `zig build yix-lsp-smoke`：真实 ZLS 端到端——悬停 `labelOf` 得到签名、跳转回 .yix 定义行、跨文件跳转到 `mod.zig`、
  `S.` 之后补全出样式导出、属性值 / 插值写到一半（.yix 编译不过）时照样补全、Zig 语法错误报在 .yix 的对应行、
  Yix 语法错误给 Yix 诊断、内置组件 / Yix 组件 / 宿主元素的属性名补全、标签名补全、没有 ZLS 时的降级（5 项）；.yss 的诊断、属性 / 颜色 token / 枚举值 / 条件 / when 维度与选项补全、属性 / token / 配方悬停、大纲、照搬 Zig 走 ZLS、mixin 跳转、从 .yix 跳到 .yss 的声明、examples 里命名模块 `@import("ui")` 可解析、保存时写回双胞胎（共 45 项）。
- `python3 tests/yix/lsp/review_versions.py zig-out/bin/yix-lsp`：用 ZLS stub 复现并验证跨编辑的请求回包、合并通知的诊断、显式过期诊断和磁盘双胞胎与源码不一致时的跳转。
- `cd editors/vscode-yix && npm test`：语法分词（标签 / 组件 / 属性 / 字符串值 / 子元素文本 / 插值 / 控制流里的标签 / `a < b` 不是标签；.yss 的条件含 `:focus-visible`、8 位十六进制颜色、`rgba()`）；工具发现回归实际执行扩展的 resolver 与启动逻辑，覆盖显式配置、工作区优先级、PATH / 扩展缓存回退和 Windows `.exe`。

## 已知限制

1. **正在输入的容错有限**：编译失败时在光标后试一组闭合串（`}`、`)}`、`/>` …）修补后服务请求，覆盖「属性值 / 插值写到一半」；
   光标之外别处的语法错误仍会让请求回空。
2. **模板位置的智能**：已有标签名补全（宿主标签 + 本文件组件）与属性名补全（宿主元素静态表；组件经 ZLS 查定义后用 `std.zig.Ast`
   解析 `<名字>Props` 字段与文档注释，camelCase，过滤已写属性；Yix 组件与手写 Zig 组件都适用）。属性名悬停、
   属性值的类型感知补全（枚举成员等）未做；props 不叫 `<名字>Props` 的手写组件取不到。
3. **改名（rename）、语义着色、格式化**未代理；`zenit fmt` 未做。
4. 扩展未打包（bundle），vsce 提示文件数多；不影响使用。
5. **无版本号的 ZLS 诊断只能尽力映射**：通知可能合并或重复，不能按数量推断文档版本；有 `version` 时只接受当前虚拟版本，没有时使用最新成功编译的映射，无法可靠识别旧版本诊断。源码编译失败或使用光标修补时暂停发布 ZLS 诊断。请求回包记录源码代次和虚拟版本，编辑或关闭后拒绝旧回包；磁盘双胞胎输出与当前源码不一致时保留生成文件位置，避免错误跳转。
