# Zenit Zig 0.17 ZLS dependency

Vendored source from local compatibility commit `d3fdd8c331868d8f94fc6b87c3fa37f679c4c353`.
Upstream: https://github.com/zigtools/zls (MIT; see LICENSE).
Base: `eab2be0fd74443a27662da809b771c4ad0d2afcf`.
Build-system integration: upstream draft PR https://github.com/zigtools/zls/pull/3270,
commit `9b57f17367e2a11ddb6af0efcbe992c82709d165` (Techatrix), cherry-picked as `d615ba5`.
Local fixes: `7d1004e945c83f26f7d2bbb7f51b51f267d862f5`; regression crash reporting: `d3fdd8c`.

Tracked source was exported with git archive, without binaries, caches or a nested Git repository.
This directory is the authoritative dependency for this Zenit branch; no separate GitHub fork is required.
Transitive dependencies are pinned by hashes in build.zig.zon. See ZIG017.md for fixes and protocol limits.

From the Zenit root, `zig build zls` installs `zig-out/bin/zenit-zls` (Windows: `.exe`).
`zig build dev-tools` installs both it and yix-lsp. `zig build test-zls` runs the upstream
suite and real build-protocol regressions. Use Zig 0.17.0.
The build is isolated so ordinary framework consumers do not compile or link editor tools.
