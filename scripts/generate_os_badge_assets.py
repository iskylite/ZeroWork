#!/usr/bin/env python3
"""Generate official OS favicons and their necessary status masks."""
import argparse
import base64
import io
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "src/ui/assets/host-os"
SOURCES = {
    "ubuntu": ("https://ubuntu.com/static/favicons/COF-favicon-48x48.png?v=fa3c63f", "https://ubuntu.com/"),
    "sugon": ("https://www.sugon.com/style/home/images/favicon.ico", "https://www.sugon.com/"),
    "deepin": ("https://www.deepin.org/index/favicon.ico?20220802", "https://www.deepin.org/"),
    "freebsd": ("https://www.freebsd.org/favicon.ico", "https://www.freebsd.org/"),
    "netbsd": ("https://www.netbsd.org/favicon.ico", "https://www.netbsd.org/"),
    "debian": ("https://www.debian.org/favicon.ico", "https://www.debian.org/"),
}


def save_badge(name, image, alpha):
    image = image.resize((72, 72), Image.Resampling.LANCZOS)
    png = io.BytesIO()
    image.save(png, format="PNG")
    encoded = base64.b64encode(png.getvalue()).decode("ascii")
    (DEST / f"{name}.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72">'
        f'<image width="72" height="72" href="data:image/png;base64,{encoded}"/></svg>\n'
    )
    (DEST / f"{name}.rgba").write_bytes(image.tobytes())
    if alpha is not None:
        mask = Image.new("RGBA", (72, 72), "white")
        mask.putalpha(alpha.resize((72, 72), Image.Resampling.LANCZOS))
        (DEST / f"{name}-status.rgba").write_bytes(mask.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Use downloaded NAME.source files")
    parser.add_argument("--only", nargs="+", choices=SOURCES, help="Regenerate only selected OS artwork")
    args = parser.parse_args()
    for name, (url, referer) in SOURCES.items():
        if args.only and name not in args.only:
            continue
        if args.source_dir:
            raw = (args.source_dir / f"{name}.source").read_bytes()
        else:
            request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Referer": referer})
            with urlopen(request, timeout=30) as response:
                raw = response.read()
        source = Image.open(io.BytesIO(raw))
        if hasattr(source, "ico"):
            source = source.ico.getimage(max(source.ico.sizes(), key=lambda size: size[0] * size[1]))
        source = source.convert("RGBA")
        if source.width != source.height:
            raise ValueError(f"{name} favicon is no longer square; verify the source again")
        if name == "ubuntu":
            # The official favicon is opaque white-on-orange. Recover the
            # antialiased white figure for red/gray connection-state masks.
            alpha = source.getchannel("B").point(lambda value: max(0, min(255, round((value - 32) * 255 / 223))))
            badge = source
        elif name == "sugon":
            # Sugon's official favicon is already a square with transparent
            # padding. A white tile retains the source red/gray wordmark.
            alpha = source.getchannel("A")
            badge = Image.new("RGBA", source.size, "white")
            badge.alpha_composite(source)
        elif name == "deepin":
            # The white swirl sits on an opaque blue circle. Extract its
            # antialiased foreground so state tinting retains the swirl.
            foreground = source.getchannel("R").point(lambda value: max(0, min(255, round((value - 30) * 255 / 225))))
            alpha = ImageChops.multiply(foreground, source.getchannel("A"))
            badge = source
        else:
            # Preserve the official favicon's frame and transparent padding.
            badge, alpha = source, None
        save_badge(name, badge, alpha)
        print(name)


if __name__ == "__main__":
    main()
