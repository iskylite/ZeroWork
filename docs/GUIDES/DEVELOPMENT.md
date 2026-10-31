# 开发与验证手册

目标为 Apple Silicon、macOS 14+、Zig 0.17.0。原生界面使用仓库固定的 Zenit 依赖；设计基准位于 `docs/DESIGN`、`docs/SPEC` 和可编辑的 `docs/UI_V3`。

## 构建与测试

在仓库根目录执行：

```sh
./scripts/build_ssh_deps.sh
zig build -j2
./scripts/test_isolated.sh test test-ui -j2
sh scripts/test_ssh_native.sh
```

提交前运行 `./scripts/verify_source_gate.sh`，校验 vendor 完整性、重建 SSH 依赖并执行单元和契约测试。隔离测试脚本使用临时数据目录，不写入用户应用数据。界面改动还需检查相关真实窗口及交互，编译通过不能代替视觉与行为检查。

## 可编辑原型与原生预览

在仓库根目录运行 `python3 -m http.server 8768 --bind 127.0.0.1 --directory.`，打开 `/docs/UI_V3/index.html`。原型场景与组件约束见 [设计入口](../UI_V3/README.md)和[设计规范](../DESIGN/DESIGN_STANDARDS.md)。

独立原生预览使用 `zig build mockup -Dmockup=<name>`；`scripts/preview_mockup.sh <name> --bg` 将其包装为 macOS App。预览只用于核对组件，不替代主程序中的真实状态与数据接线。

## 仓库内容与临时输出

Git 管理设计文档和原型、核心代码、测试代码、使用手册，以及构建所需配置、依赖、资源和许可证。验收台账、截图、测量报告、审计、发布安装记录、日志、缓存和打包产物不纳入版本管理。临时验证输出优先使用仓库外的临时目录；仓库内相应目录由 `.gitignore` 排除。
