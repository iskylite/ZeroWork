#!/usr/bin/env python3
"""Generate selective contrast helpers without changing the source OS logos.

Only normal/source-colour artwork consumes these derivatives. Connection state
masks continue using the original RGBA, so helper ink never becomes a status fill.
Requires Pillow; no logo downloads or source SVG/RGBA rewrites.
"""
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

DEST = Path(__file__).resolve().parents[1] / "src/ui/assets/host-os"
TREATMENTS = {
    "debian": "fine rose contour",
    "alpine": "ice-blue mountain negative space",
    "freebsd": "fine warm-gray contour",
    "bclinux": "cream penguin negative space",
    "netbsd": "local ivory contour around gray lettering",
    "redflag": "local ivory contour around the black Linux lettering",
}


def enclosed(alpha):
    """Fill only closed transparent holes; leave exterior padding transparent."""
    width, height = alpha.size
    wall = alpha.point(lambda a: 255 if a >= 32 else 0)
    exterior = set()
    pending = deque((x, y) for y in range(height) for x in range(width)
                    if (x in (0, width - 1) or y in (0, height - 1)) and wall.getpixel((x, y)) == 0)
    while pending:
        x, y = pending.popleft()
        if (x, y) in exterior:
            continue
        exterior.add((x, y))
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in exterior and wall.getpixel((nx, ny)) == 0:
                pending.append((nx, ny))
    mask = Image.new("L", alpha.size)
    mask.putdata([255 - alpha.getpixel((x, y)) if (x, y) not in exterior else 0
                  for y in range(height) for x in range(width)])
    return mask


def contour(mask, opacity):
    # One source pixel is 0.19 logical pixels at the smallest 14px icon size.
    return mask.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(.35)).point(lambda a: round(a * opacity))


def generate(name):
    source = Image.frombytes("RGBA", (72, 72), (DEST / f"{name}.rgba").read_bytes())
    alpha = source.getchannel("A")
    if name in ("alpine", "bclinux"):
        mask = enclosed(alpha)
        colour = "#dcebf2" if name == "alpine" else "#f1e6c9"
    else:
        mask = alpha
        if name in ("netbsd", "redflag"):
            mask = Image.new("L", source.size)
            mask.putdata([a if max(r, g, b) - min(r, g, b) < 48 and max(r, g, b) < 180
                          and (name != "redflag" or i // 72 >= 40) else 0
                          for i, (r, g, b, a) in enumerate(source.get_flattened_data())])
        mask = contour(mask, .8 if name in ("netbsd", "redflag") else .6)
        colour = {"debian": "#e9c3cd", "freebsd": "#e5d4ce"}.get(name, "#eee5d4")
    helper = Image.new("RGBA", source.size, colour)
    helper.putalpha(mask)
    result = Image.alpha_composite(helper, source)
    assert result.tobytes() != source.tobytes(), name
    for before, after in zip(source.get_flattened_data(), result.get_flattened_data()):
        assert after[3] >= before[3], name
        if before[3] == 255:
            assert before == after, (name, before, after)
    (DEST / f"{name}-contrast.rgba").write_bytes(result.tobytes())


if __name__ == "__main__":
    for name, treatment in TREATMENTS.items():
        generate(name)
        print(f"{name}: {treatment}")
