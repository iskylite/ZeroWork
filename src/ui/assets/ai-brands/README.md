Brand SVGs from https://github.com/lobehub/lobe-icons/tree/master/packages/static-svg/icons (MIT, see LICENSE). Brand marks belong to their respective owners. Bundled locally; no runtime requests. Paths were expanded to absolute, space-separated commands (arcs converted to cubic curves) with fontTools SVGPathPen to support the native SVG parser.

Regenerate native geometry from repository root:

```sh
zig run --dep icon_ir --dep svg -Mroot=vendor/zenit/tools/gen_svg_assets.zig -Micon_ir=vendor/zenit/src/icon_ir.zig --dep icon_ir --dep svg_safety -Msvg=vendor/zenit/src/render/svg.zig -Msvg_safety=vendor/zenit/src/svg_safety.zig -- src/ui/assets/ai-brands src/ui/ai_brand_assets.zig assets/ai-brands/ 54500
zig fmt src/ui/ai_brand_assets.zig
```
