# V3 字体资源

HTML 与原生使用相同的原始字体资源。原生在创建窗口前将嵌入的 TTF 注册到当前进程，不安装或改变系统字体。

| 实际 family | 资源 / 版本 | 支持字重 | 官方来源与许可证 |
| --- | --- | --- | --- |
| Inter Variable | `InterVariable.ttf` / `InterVariable.woff2`，4.001 | 可变 | [Inter 官方](https://github.com/rsms/inter/tree/master/docs/font-files)，`Inter-OFL.txt` |
| JetBrains Mono | `JetBrainsMono-Regular.ttf`，2.305 | Regular | [JetBrains 官方](https://github.com/JetBrains/JetBrainsMono/tree/master/fonts/ttf)，`JetBrainsMono-OFL.txt` |
| Fira Code | `FiraCode-{Light,Regular,Medium,Bold}.ttf`，6.002 | 300 / 400 / 500 / 700 | [Fira Code 6.2 官方发布包](https://github.com/tonsky/FiraCode/releases/tag/6.2)，[原始 OFL](https://github.com/tonsky/FiraCode/blob/6.2/LICENSE)，`FiraCode-OFL.txt` |
| Source Code Pro | `SourceCodePro-{Light,Regular,Medium,Bold}.ttf`，2.042 | 300 / 400 / 500 / 700 | [Adobe 官方固定版本 d3f1a59](https://github.com/adobe-fonts/source-code-pro/tree/d3f1a59/TTF)，[原始 OFL](https://github.com/adobe-fonts/source-code-pro/blob/d3f1a59/LICENSE.md)，`SourceCodePro-OFL.txt` |

Inter 与 JetBrains 获取于 2026-10-25；Fira Code 与 Source Code Pro 获取于 2026-11-01。`manifest.json` 记录所有字体与许可证的字节数和 SHA-256；字体本体未修改。Fira Code 和 Source Code Pro 使用静态字重，匹配当前原生 family / weight 查找方式。原生 `test-font` 验证两套字体的真实 family、四字重与 8 / 14 / 48 pt 度量，防止界面显示已选字体却实际替换字重。

`native.zig` 嵌入 TTF，`src/platform/ui_fonts.{zig,m}` 以 CoreText 进程内方式注册；`scripts/package_macos.sh` 将四份 OFL 一起复制到应用 Resources。UI 字体的 CSS 别名 `Inter` 显式映射到原生实际 family `Inter Variable`。终端字体经同一 FontRegistry 解析、测量和绘制，中文等缺失字符由系统字体 fallback 补足。

字体设置区分“内置”和“未安装”，同时枚举可用的已安装等宽字体。建议列表中的其他名字只是候选；只有实际原生 family 可解析时才标为可用。自定义输入支持列表外 family 与 Nerd Fonts，缺失字体会保留请求名并明确报告实际 Menlo fallback。浏览器验收使用显式 FontFace 加载状态，不能仅用 `document.fonts.check()` 证明系统 family 存在。
