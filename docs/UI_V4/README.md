# UI_V4 · SVG 设计

当前三个设计稿使用独立的“晴霜”主题，配色取自最初参考图。

本目录以可编辑 SVG 为设计基准，与 `docs/UI_V3` 的 HTML/CSS 原型分开。

| 当前设计稿 | 逻辑视口 |
| --- | --- |
| [主工作区](mist-workspace.svg) | 1440 × 900 |
| [窄窗口收起态](mist-workspace-compact.svg) | 860 × 480 |
| [窄窗口展开态](mist-workspace-compact-expanded.svg) | 860 × 480 |

设计前阅读 [设计要求](DESIGN_REQUIREMENTS.md) 和 [风格指南](STYLE_GUIDE.md)。精确布局与行为约束见 [主界面规范](mist-design.md)。

**本目录只允许 `.svg` 和 `.md` 文件。禁止存放 PNG、JPG、WebP、GIF 等图片，也不存放截图、预览、验证报告、日志、JSON 或脚本。** SVG 必须是可编辑设计稿，不用 SVG 外壳包装截图。

生成器与验证器位于 `tools/ui_v4/`；本地导出、截图、测量和机器报告统一写入仓库外部的临时目录，或仓库根目录已忽略的 `artifacts/ui-v4/`。运行：

```sh
python3 tools/ui_v4/generate_mist.py
python3 tools/ui_v4/verify_mist.py
```

本目录仅保留最新设计，不存放历史方案和逐次修订记录。
