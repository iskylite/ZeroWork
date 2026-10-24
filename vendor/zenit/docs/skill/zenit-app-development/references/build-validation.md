# 构建与验证

区分框架根目录的示例步骤与消费应用自己的 build 步骤。先读 `zig build --help` 和项目测试约定，不要把框架命令强加到消费 app。

## 平台构建

macOS 框架示例：`zig build run-storybook`、`zig build run-hello-button`；消费 app 用自己的 `zig build` / `run` / `app`。`zenit.bundleApp` 负责 .app，不能用作 Windows 打包。

Windows 框架 Storybook（PowerShell）：

```powershell
zig build windows-storybook -Dwindows-arch=x86_64 -Dgpu-backend=d3d12 -Doptimize=fast
if ($LASTEXITCODE -ne 0) { throw 'Storybook build failed' }
.\zig-out\bin\zenit-windows-storybook.exe
```

推荐用 `windows-*`；历史 `windows-arm64-*` 是兼容别名，不代表固定 ARM64。架构由 `-Dwindows-arch` 决定，Windows x64 主机默认 x86_64，其余主机默认 aarch64。专用 UI 步骤必须显式选 D3D12 才有真实 GPU GUI，不能把 Null 后端当渲染验收。gallery 的指针合同仅在 `-Dtest-mode=true` 时注册，普通构建不开放测试输入注入。

消费 app 从 minimal template 改 build 时向 Zenit 依赖显式转发：

```zig
.@"windows-arch" = target.result.cpu.arch,
.@"gpu-backend" = if (target.result.os.tag == .windows) "d3d12" else "metal",
```

该示例只覆盖 macOS/Windows；其他平台先查支持范围。Windows 用 `zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast`（ARM64 换目标）；不能假定 MSVC 与公开模块 wiring 相同。依赖 `.path` 使用相对路径。交叉编译生成 EXE 以后，仍须在 Windows 执行交互验收。

## 应用 E2E

读 `docs/HARNESS.md`、项目 `e2e/` 与已安装 scenario skills。依赖 build 选项与应用隔离，必须转发 `test-mode/e2e-port`；调用 `zenit.installHarnessClient` 后客户端在 `zig-out/share/zenit/harness/client.ts`。

应用与 Bun controller 同时设置相同、唯一的 `ZENIT_E2E_FILE_RPC_DIR`。使用稳定 test_id 和状态断言；不能只有启动或固定 sleep 就算行为通过。生产构建关闭 Harness。截图用于布局/视觉判断，键盘输入、焦点、IME、浮层和无障碍按本次改动选相关路径。

用户要求 Windows 全套验收时，按 `docs/WINDOWS_BUILD.md` 先构建所有待验程序（Storybook、text-input、render-gallery、GPU resources contract），准备 ZIP、脚本、Bun 和 batch plan，一次传齐，目标机本地顺序运行。不要逐项跨机通信测试。使用脚本当前 CLI 确认选项与文件名；验收证据必须包含退出码、完整结果行、失败产物。不得静默去掉 `--require-a11y` 或放宽门槛。

## 验证范围

- 应用功能：生成检查 + 目标构建 + 真实交互/相关 scenario；业务逻辑测试按复杂度补充。
- 修框架 Yix/Yss：`check-yix`、`test-yix`；改 schema 加 `check-yss-schema`；改编辑器/协议加 `dev-tools yix-lsp-smoke`。
- 修响应式/核心 UI：当前 `test-reactive`、`test-ui` / `test-ui-core` 相关测试，再跑受影响 app E2E。核对宿主支持，不能假设所有测试可直接运行在 Windows。
- 用户或仓库要求完整 gate：按其规定全部执行，不能以本表的局部验证代替。

测试里故意运行失败 CLI 的用例可能输出错误；通过退出码及具体断言区分负例和真实失败。最终明确区分 build、软件 gate 和硬件运行证据，无法执行的项目须如实说明原因。
