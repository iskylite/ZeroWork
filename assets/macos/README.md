# ZeroWork 应用图标

源自本地 Figma Bridge 文件「ZeroWork · 交互原型」的 `239:573635`（`ZeroWork · App Logo · 64px`）。节点实际尺寸为 128×128；PNG 按 8 倍导出为 1024×1024，SVG 保留原始矢量。没有重新绘制或替换设计。

`AppIcon.icns` 包含 macOS 的 16、32、128、256、512 点及对应 2 倍资源。更新原型导出后，在 macOS 运行：

```sh
sh scripts/build_app_icon.sh
```

正式打包、本地 UI 验收和原生输入验收包将该文件复制到 `Contents/Resources/AppIcon.icns`，通过 `CFBundleIconFile=AppIcon` 声明。需要重启新应用包后检查系统图标；不要覆盖正在运行的应用包。
