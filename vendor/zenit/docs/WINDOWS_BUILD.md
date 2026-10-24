# Windows 构建与批量验收

本指南使用 Zig 0.17.0。Windows 使用 Win32、DirectWrite 和 D3D12；支持 `x86_64` 与 `aarch64`。普通 Intel/AMD PC 选 `x86_64`，Windows on Arm 选 `aarch64`。运行验收需要在目标 Windows 机器上执行。

## 工具与架构

- [下载 Zig **0.17.0**](https://ziglang.org/download/)，先运行 `zig version` 确认；Zig 0.17 优化参数为 `debug / safe / fast / small`。
- 构建 GUI 不需要 Node 或 Bun；Yix/Yss 生成器由 Zig 构建并在构建主机运行。
- 批量验收准备需要 Python 3 和 Bun；编辑器扩展打包需要 Node/npm。
- macOS 可以交叉编译 Windows `.exe`；Windows PowerShell 也可运行相同构建目标。
- 推荐使用架构中立的 `windows-*` 构建目标；`windows-arm64-*` 保留为兼容别名。**实际架构由 `-Dwindows-arch` 决定**，Windows x64 主机默认 `x86_64`，Windows ARM64 主机与其他交叉编译主机默认 `aarch64`，与步骤名无关。
- GUI 必须显式传 `-Dgpu-backend=d3d12`。这些专用 Windows App 目标未选 D3D12 时使用 Null 后端，不能证明实际 GPU 渲染。

## Windows PC 本机构建

在仓库根目录执行 PowerShell，普通交互示例先不打开测试模式：

```powershell
zig version
zig build windows-storybook windows-text-input windows-render-gallery -Dwindows-arch=x86_64 -Dgpu-backend=d3d12 -Doptimize=fast --prefix .\out\windows-x64
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
.\out\windows-x64\bin\zenit-windows-storybook.exe
```

普通 gallery 构建不执行创建临时窗口、字体截图等启动合同，也不注册测试专用的指针输入注入回调，其余渲染展示保持可用。需要执行指针合同与 Harness 自动验收时，另加 `-Dtest-mode=true`，并使用独立 prefix，避免覆盖普通程序。不要把 gallery 这个含原生合同探针的回归工具当成生产发布应用。

输出均在所选 prefix 的 `bin` 目录：

| 构建目标 | 输出程序 | 用途 |
| --- | --- | --- |
| `windows-storybook` | `zenit-windows-storybook.exe` | 共享 Storybook、组件交互、DevTools |
| `windows-text-input` | `zenit-windows-text-input.exe` | 文本编辑、IME 示例 |
| `windows-render-gallery` | `zenit-windows-render-gallery.exe` | 图像、纹理和渲染回归 |
| `windows-app-gate` | `zenit-windows-app-gate.exe` | 公开 App 运行时探针 |
| `windows-ui-probe` | `zenit-windows-ui-smoke.exe` | UI 交互探针 |
| `windows-gpu-resources-contract` | `zenit-windows-gpu-resources-contract.exe` | D3D12 原生资源与 GPU 合同 |

Windows on Arm 将架构改成 `aarch64`，使用独立 prefix。GPU 合同是独立目标，应带 `-Dwindows-gpu-contract-scope=all`。

## macOS 交叉编译整套验收程序

在仓库根目录一次准备四个程序。测试模式打开 Harness，日常发布不要带 `-Dtest-mode=true`。

```sh
zig build windows-storybook windows-text-input windows-render-gallery \
  -Dwindows-arch=x86_64 -Dgpu-backend=d3d12 -Doptimize=fast -Dtest-mode=true \
  --prefix /tmp/zenit-windows-x64
zig build windows-gpu-resources-contract \
  -Dwindows-arch=x86_64 -Dwindows-gpu-contract-scope=all -Doptimize=fast \
  --prefix /tmp/zenit-windows-x64
```

这两个目标组显式选择 Windows GNU 目标，不需要再加 `-Dtarget`。构建成功仅证明交叉编译和链接成功，Windows 运行结果仍须在目标机器检查。

## 程序、脚本、运行时一起打包

```sh
python3 tools/windows_batch.py --arch x86_64 --skip-build \
  --artifact-dir /tmp/zenit-windows-x64/bin --require-a11y \
  --prepare-only --output-dir /tmp/zenit-windows-payload
```

Windows 构建主机使用 `python` 和自己的目录，例如 `--artifact-dir .\out\windows-x64\bin`。此命令只准备，不连接 worker。它校验 PE 架构、将全部套件打成 Bun 可执行的 JS，并准备匹配的 Windows Bun；首次准备可能需要下载运行时。

输出包括 `zenit-batch.zip`、`zenit-bun.exe` 和 `batch-plan.json`。ZIP 内含四个程序、套件和 `manifest.json`；不要只传 `.exe`。当前默认严格计划是 31 个阶段，完整覆盖渲染、输入、原生 GPU 和 UI Automation。

使用已连接的、与仓库同版本的 worker，一次提交整批：

```sh
python3 tools/windows_batch.py --base "$ZENIT_VM_BASE" --arch x86_64 \
  --skip-build --artifact-dir /tmp/zenit-windows-x64/bin --require-a11y
```

PowerShell 环境变量写法为 `$env:ZENIT_VM_BASE`。worker 在交互式桌面中运行，测试期间每个 Harness 请求都在 Windows 本地执行；主机只提交计划、收回证据。工具会重新准备提交包，上面的 `--prepare-only` 用于离线检查，不是对已准备目录的提交参数。

证据分片上传后验证 SHA-256，可重试并保留已完成分片。最终验收要求进程退出成功、整批状态通过且 `batch-report.json` 每个阶段通过；不能只看 PowerShell 的 “finished”。`--require-a11y` 必须保留，否则 UIA 失败可能只报告而不阻止整批通过。

队列地址、token 和系统登录凭据保存在仓库外的本地配置，不应提交到 Git。

## 消费项目的 Windows 参数

应用使用 `zenit.attach(dep, exe)`，`main(init: std.process.Init)` 向 App 配置传 `.io = init.io`。依赖项目的 `build.zig` 必须将架构和后端传给 Zenit；只在应用命令行写选项，并不会自动传递给依赖：

```zig
const dep = b.dependency("zenit", .{
    .target = target,
    .optimize = optimize,
    .@"windows-arch" = target.result.cpu.arch,
    .@"gpu-backend" = if (target.result.os.tag == .windows) "d3d12" else "metal",
});
zenit.attach(dep, exe);
```

按当前 Windows 模块导出条件，目标使用 GNU ABI：

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast
```

这里是消费项目的普通 install 步骤；仓库的 `windows-*` 专用目标则使用上一节命令。ARM 消费项目使用 `aarch64-windows-gnu`。`.app` 打包只适用于 macOS，Windows 直接运行 `.exe`。

`zenit.attach()` / `addNativeLibs()` 为 Windows 程序设置至少 32 MiB 的栈地址空间预留，以容纳 Debug 渲染器初始化的临时值；调用方已经设置的更大预留会保留。这是地址空间预留，并非启动时提交 32 MiB 内存。

## 常见问题与检查

- **程序无法启动 / 架构错误**：程序、`--arch` 和目标机器架构应一致；ARM 机器的 Bun 使用准备工具选择的 x64 runtime，依赖系统仿真。
- **能打开窗口却没有实际 GUI 渲染**：检查 `-Dgpu-backend=d3d12` 和所运行的 exe 是否来自本次 prefix。
- **生成物过期**：运行 `zig build gen-yix`，再用 `zig build check-yix` 确认；Yix/Yss 源和双胞胎一起提交。
- **传包完成但验收失败**：查看整批报告的失败阶段及应用日志；完整 UIA 需要可交互的 Windows 桌面。

离线合同测试：

```sh
zig build test-windows-batch test-windows-upload
```

录屏支持和限制见 [WINDOWS_RECORDING.md](WINDOWS_RECORDING.md)；Yix/Yss 开发见 [YIX_YSS_GUIDE.md](YIX_YSS_GUIDE.md)。
