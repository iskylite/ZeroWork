# Counter pixel baseline

Four 960×800 RGBA renderer screenshots, captured on 2026-10-04 after the application
Design System token cleanup and before the hover/ref/Yix review fixes. Hand-written
Counter and Yix Counter both match these images exactly after the fixes.

The snapshots cover initial state, one increment, count=2 with the badge hovered,
and reset. They are versioned fixtures rather than ignored `reports/` outputs.

Run from the repository root on macOS with Zig 0.17.0, Bun, and Pillow available:

```sh
bash scripts/capture_counter.sh counter-reactive /tmp/zenit-counter-check/zig
bash scripts/capture_counter.sh yix-counter /tmp/zenit-counter-check/yix
python3 scripts/compare_rgba.py tests/fixtures/counter /tmp/zenit-counter-check/zig /tmp/zenit-counter-check/zig.json
python3 scripts/compare_rgba.py tests/fixtures/counter /tmp/zenit-counter-check/yix /tmp/zenit-counter-check/yix.json
```

Comparison has no tolerance, crop, mask, or ignored alpha. Renderer/font/platform
changes may require reviewing a new baseline; a mismatch is not auto-approved.
