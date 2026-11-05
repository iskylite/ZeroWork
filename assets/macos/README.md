# ZeroWork 应用图标

当前标识为 Zero 蜥蜴双手持终端，2026-10-26 用户确认设计。

- `AppIcon.png`：1024 × 1024，默认透明背景，README、安装包和启动时默认使用。
- `AppIcon-light.png`：1024 × 1024，浅色（暖白）底板。
- `AppIcon-dark.png`：1024 × 1024，深色（炭黑）底板。
- `AppIcon.svg`：嵌入默认 PNG 的 SVG 容器，并非可编辑路径矢量稿。
- `AppIcon.icns`：默认透明图标，包含 macOS 的 16、32、128、256、512 点及对应 2 倍资源。
- `icons.zig`：将三种 PNG 编入应用，无需运行时访问源码目录。
- `preview.html`：三种底色的实际素材预览。

设置 → 外观与主题 → 应用图标提供透明背景、白底、黑底。配置为 `[ui] icon_background = "transparent" | "light" | "dark"`，默认 `transparent`。选择经现有设置事务保存后，同时更新运行中的 Dock 图标和应用文件的自定义图标；取消不更新，退出后保留，启动时重新应用。使用 `NSWorkspace.setIcon` 保存自定义图标，不替换签名 `Contents` 内的资源；Finder 等系统位置也使用所选图标。应用必须位于当前用户可写的目录中，从只读磁盘映像启动时无法持久保存。直接运行未打包的可执行文件时只更新运行中的 Dock 图标。

签名验证：Finder 自定义图标会在应用文件上增加 `com.apple.FinderInfo` 等元数据，`codesign --verify --strict` 会将其报告为不允许的附加数据；常规 `codesign --verify --deep` 及更新器使用的 `SecStaticCodeCheckValidity(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)` 仍应通过。打包时先对无自定义文件图标的新应用完成严格签名校验，再由安装后的应用设置自定义图标。

重建默认安装图标：

```sh
sh scripts/build_app_icon.sh
```

正式打包、本地 UI 验收和原生输入验收包使用 `Contents/Resources/AppIcon.icns`，由 `CFBundleIconFile=AppIcon` 声明。更新后需使用新应用包启动；既有安装包不会随源码资源自动更新。

## 素材来源与署名

改编自 Zig Software Foundation 官方仓库的 [Zero the Ziguana](https://github.com/ziglang/logo/blob/master/zero.svg)，原吉祥物依 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 授权，参见 [上游说明](https://github.com/ziglang/logo#official-mascots)。ZeroWork 版本使用内置 ImageGen 改编：简化构图，改为双手持终端，制作三种背景。此改编不表示 Zig 官方背书。

生成提示概要：保留绿脸、橙色宇航服、透明头盔及卷尾；双手抱住炭黑 `>_` 终端；紧凑应用图标构图；默认去除底板并保留 alpha，另备浅色和深色底板。
