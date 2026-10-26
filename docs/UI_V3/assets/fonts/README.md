# V3 字体资源

为避免“CSS声明Inter但实际用系统fallback”的伪对齐，HTML自带字体并从本地静态服务加载，不安装或改变系统字体。

- `InterVariable.woff2` / `InterVariable.ttf`：Inter官方仓库 `https://github.com/rsms/inter` 的 `docs/font-files/`。浏览器用woff2，TTF由原生构建嵌入并在当前进程注册，采用同一字体。许可证 `Inter-OFL.txt`。
- `JetBrainsMono-Regular.ttf`：JetBrains官方 `https://github.com/JetBrains/JetBrainsMono` 的 `fonts/ttf/`。许可证 `JetBrainsMono-OFL.txt`。
- 获取日期2026-10-25。均遵循附带SIL Open Font License，不改字体本体。

原生必须以相同字体资源/真实family注册及FontRegistry解析结果进行测量、绘制、命中、选区和IME；`document.fonts.check`对不存在的系统family也可能返回true，不能拿它证明实际字体。浏览器验收同时查看显式FontFace加载状态。当前项目有FontSystem.loadFont(path,size)，但FontRegistry.resolve仍通过family查找，TTF随包携带不自动意味着已注册进该family路径；需打包/注册后实机检查，不允许界面显示Inter却静默换字体。

TTF name表已核对：Inter Variable，Version4.001/git-9221beed3，PostScript InterVariable；JetBrains Mono，Version2.305，PostScript JetBrainsMono-Regular。CSS字体别名Inter不等于原生family名Inter Variable，落地映射必须显式处理。

原生接线：`native.zig` 仅嵌入现有两个 TTF；`src/platform/ui_fonts.{zig,m}` 在进程内注册，UI family 显式映射为 `Inter Variable`，App fallback 与 process FontSystem 一致。终端用户所选字体仍由原有 FontRegistry 解析。Release 包在 Resources 中携带两份 OFL 许可证。四通路、同句 Range、输入选区与真实 SCIM 证据见 `dist/verification/font-unification-20261026/`。
