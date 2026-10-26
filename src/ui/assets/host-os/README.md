# Saved-host colour icons

Linux, Ubuntu, Debian, Fedora , Arch Linux and Rocky Linux: Devicon original SVGs, MIT license
(included as LICENSE). Source: https://github.com/devicons/devicon/tree/master/icons

These assets are exclusive to saved hosts; tab glyphs retain status tinting.
`src/ui/host_os_assets.zig` assigns independent IDs to these resources.
Before the renderer is ready, existing native geometry supplies a fallback;
once ready, saved-host nodes use source-colour textures. Tabs never use them.

Alpine Linux and FreeBSD SVGs come from Simple Icons (CC0):
https://github.com/simple-icons/simple-icons . Their brand fills are #0D597F and
#AB2B28. Windows 11 is from Devicon (MIT).

`.rgba` files are 72×72 straight RGBA browser renders on transparent backgrounds
(4× the logical 18px host slot). They preserve multicolour fills and gradients;
the framework's icon geometry deliberately supports only theme tint. Each window
uploads and owns its host artwork textures, releasing them on window cleanup.
To regenerate, render each SVG at 72×72 with transparent background in Chromium,
then export `PIL.Image.open(png).convert('RGBA').tobytes()` to the matching file.

Rocky Linux: `rockylinux/rockylinux-original.svg` from the Devicon source above.
The matching tintable tab geometry is `src/ui/rocky_os_asset.zig` (ID 54003).
Regenerate it with zenit's `gen_svg_assets` tool using an input directory that
contains only `rocky.svg`, embed prefix `assets/os/`, and base icon ID 54003;
this keeps the existing tab asset IDs stable.
