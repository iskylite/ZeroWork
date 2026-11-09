#!/usr/bin/env python3
"""Regenerate source-colour OS artwork (requires Pillow and resvg-py).

Official brand marks are used only to identify the remote operating system.
Existing host icon IDs are retained; see src/ui/assets/host-os/README.md.
"""
import argparse
import base64
import io
from pathlib import Path
import urllib.request

from PIL import Image
import resvg_py
from os_logo_extract import prepare

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "src/ui/assets/host-os"
SOURCES = {
    "kylin": "https://raw.githubusercontent.com/ukui/ukui-themes/master/icons/ukui-classical/scalable/places/start-here.svg",
    "neokylin": "https://p3-sdbk2-media.byteimg.com/tos-cn-i-xv4ileqgde/d9fb1b4ea2554a70baa0ac24db8f2f51~tplv-xv4ileqgde-resize-w:720.image",
    "openkylin": "https://gitee.com/openkylin/openkylin-theme/raw/36f233d1d0cb7c8ca446d34ed3b6687ecfdcc282/icons/ukui-icon-theme-default/256x256/apps/distributor-logo-kylin.png",
    "ubuntukylin": "https://raw.githubusercontent.com/ubuntukylin/ubuntukylin-theme/d6038b6dfaeb1b4761458e0950753a0598d49a1b/icons/ukui/256x256/places/distributor-logo-kylin.png",
    "uos": "https://www.chinauos.com/assets/image/website_logo.ico",
    "openeuler": "https://www.openeuler.org/favicon.ico",
    "euleros": "https://mirrors.huaweicloud.com/euler/2.0/os/x86_64/Packages/euleros-logos-2.0-6.noarch.rpm",
    "anolis": "https://img.alicdn.com/imgextra/i1/O1CN01oJnJZg1yK4RzI4Rx2_!!6000000006559-2-tps-118-118.png",
    "opencloudos": "https://www.opencloudos.org/qq.ico",
    "tencentos": "https://mirrors.tencent.com/tencentos/4/BaseOS/x86_64/os/Packages/system-logos-1.0.7-2.tl4.noarch.rpm",
    "alinux": "https://indico.cern.ch/event/1477299/contributions/6427682/attachments/3044196/5378511/SUSE_hepix_2025.pdf",
    "loongnix": "https://pkg.loongnix.cn/loongnix/pool/main/l/loongnix-theme/loongnix-theme_1.0.0-1.lnd.3_loongarch64.deb",
    "aosc": "https://aosc.io/favicon.ico",
    "bclinux": "https://mirrors.cmecloud.cn/bclinux/oe21.10/OS/x86_64/Packages/bclinux-logos-1.0-9.oe1.bclinux.noarch.rpm",
    "kylinsec": "https://www.kylinsec.com.cn/Public/favicon.ico",
    "nfs": "https://www.nfschina.com/data/upload/image/20210906/1630914044118736.png",
    "linx": "https://www.linx-info.com/favicon.ico",
    "isoft": "https://www.i-soft.com.cn/uploads/images/2022/0526/LsAysk68qNl5rhhIxydktnOaSPRaoghu1TXRKKNt.png",
    "redflag": "https://www.chinaredflag.cn/static/img/hd-logo.png",
}


def generate(name, raw):
    raw = prepare(name, raw)
    if raw.lstrip().startswith((b"<svg", b"<?xml")):
        svg = raw.decode("utf-8-sig")
        (DEST / f"{name}.svg").write_text(svg)
        image = Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svg, width=288, height=288))).convert("RGBA")
    else:
        image = Image.open(io.BytesIO(raw))
        if hasattr(image, "ico"):
            image = image.ico.getimage(max(image.ico.sizes(), key=lambda size: size[0] * size[1]))
        image = image.convert("RGBA")
        bounds = image.getbbox()
        if bounds:
            image = image.crop(bounds)
        png = io.BytesIO()
        image.save(png, format="PNG")
        encoded = base64.b64encode(png.getvalue()).decode("ascii")
        (DEST / f"{name}.svg").write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{image.width}" height="{image.height}" viewBox="0 0 {image.width} {image.height}">'
            f'<image width="{image.width}" height="{image.height}" href="data:image/png;base64,{encoded}"/></svg>\n'
        )
    # Fit within the existing 18px slot, retaining transparency and source RGB.
    bounds = image.getbbox()
    if bounds:
        image = image.crop(bounds)
    image.thumbnail((72, 72), Image.Resampling.LANCZOS)
    # Pillow thumbnail does not upscale low-resolution official ICO frames.
    scale = min(72 / image.width, 72 / image.height)
    image = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (72, 72))
    canvas.paste(image, ((72 - image.width) // 2, (72 - image.height) // 2))
    (DEST / f"{name}.rgba").write_bytes(canvas.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Use already-downloaded NAME.source files")
    parser.add_argument("--only", nargs="+", choices=SOURCES, help="Regenerate only selected OS artwork")
    args = parser.parse_args()
    for name, url in SOURCES.items():
        if args.only and name not in args.only:
            continue
        raw = (args.source_dir / f"{name}.source").read_bytes() if args.source_dir else urllib.request.urlopen(url, timeout=30).read()
        generate(name, raw)
        print(name)


if __name__ == "__main__":
    main()
