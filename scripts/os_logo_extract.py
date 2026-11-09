"""Extract verified OS marks without redrawing their artwork.

RPMs are read with libarchive tar; the conventional Amazon/Alibaba Linux marks
are embedded images from the cited SUSE/Uyuni slide (requires Poppler pdfimages).
See src/ui/assets/host-os/SOURCES.md for evidence and extraction details.
"""
from collections import deque
import io
from pathlib import Path
import subprocess
import tempfile

from PIL import Image

RPM_IMAGES = {
    "bclinux": "./usr/share/icons/hicolor/256x256/apps/system-logo-icon.png",
    "euleros": "./usr/share/icons/hicolor/256x256/apps/system-logo-icon.png",
    "tencentos": "./usr/share/pixmaps/tencentos-gdm-logo.png",
}


def clear_outer_white(image):
    """Remove the connected white page matte, retaining white inside the mark."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    seen = set()
    queue = deque([(x, y) for x in range(width) for y in (0, height - 1)] +
                  [(x, y) for y in range(height) for x in (0, width - 1)])
    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or not (0 <= x < width and 0 <= y < height):
            continue
        seen.add((x, y))
        r, g, b, a = pixels[x, y]
        if a and min(r, g, b) < 235:
            continue
        pixels[x, y] = (r, g, b, 0)
        queue.extend(((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)))
    return image


def prepare(name, raw):
    if name == "loongnix" and raw.startswith(b"!<arch>\n"):
        # Read only the distribution's own launcher icon; never install/run it.
        with tempfile.TemporaryDirectory(prefix="zw-logo-deb-") as directory:
            package = Path(directory) / "theme.deb"
            package.write_bytes(raw)
            data = Path(directory) / "data.tar.xz"
            data.write_bytes(subprocess.check_output(["tar", "-xOf", str(package), "data.tar.xz"]))
            raw = subprocess.check_output(["tar", "-xOf", str(data), "./usr/share/loongnix-theme/Loongnix-Icon/places/scalable/start-here-symbolic.png"])
        image = Image.open(io.BytesIO(raw)).convert("RGBA")
        if image.size != (960, 960):
            raise ValueError("Loongnix launcher artwork changed; verify the source again")
    elif name in RPM_IMAGES and raw.startswith(b"\xed\xab\xee\xdb"):
        with tempfile.TemporaryDirectory(prefix="zw-logo-rpm-") as directory:
            package = Path(directory) / "logos.rpm"
            package.write_bytes(raw)
            raw = subprocess.check_output(["tar", "-xOf", str(package), RPM_IMAGES[name]])
        image = Image.open(io.BytesIO(raw)).convert("RGBA")
        if name == "bclinux":
            image = image.crop((0, 0, 256, 197))  # Penguin ends before the wordmark at y=201.
        elif name == "euleros":
            image = image.crop((0, 0, 256, 195))  # Flower ends at y=193; HUAWEI starts at y=215.
        else:
            image = image.crop((0, 0, 64, 45))  # Graphic from TencentOS GDM lockup.
        image = clear_outer_white(image)
    elif name in ("amazonlinux", "alinux") and raw.startswith(b"%PDF-"):
        with tempfile.TemporaryDirectory(prefix="zw-logo-pdf-") as directory:
            document = Path(directory) / "source.pdf"
            document.write_bytes(raw)
            prefix = Path(directory) / "image"
            subprocess.run(["pdfimages", "-f", "12", "-l", "12", "-png", str(document), str(prefix)], check=True)
            index = "008" if name == "amazonlinux" else "009"
            image = Image.open(Path(directory) / f"image-{index}.png").convert("RGBA")
        expected = (207, 244) if name == "amazonlinux" else (207, 243)
        if image.size != expected:
            raise ValueError("SUSE slide image layout changed; verify the logo source again")
        image = clear_outer_white(image)
    elif name == "neokylin":
        image = Image.open(io.BytesIO(raw)).convert("RGBA")
        # Locate the red product mark, excluding the black Chinese/English text.
        red = Image.new("L", image.size)
        red.putdata([255 if r > 90 and r > g * 1.25 and r > b * 1.15 and a else 0
                     for r, g, b, a in image.getdata()])
        bounds = red.getbbox()
        if bounds is None:
            raise ValueError("NeoKylin source no longer contains the verified red mark")
        x0, y0, x1, y1 = bounds
        image = image.crop((max(0, x0 - 3), max(0, y0 - 3), min(image.width, x1 + 3), min(image.height, y1 + 3)))
        image.putdata([(r, g, b, 0 if min(r, g, b) > 200 else a) for r, g, b, a in image.getdata()])
    elif name == "nfs":
        image = Image.open(io.BytesIO(raw)).convert("RGBA")
        if image.size != (59, 59):
            raise ValueError("NFS badge layout changed; verify the graphical crop again")
        image = image.crop((0, 0, 59, 46))  # The separate NFS-CHINA caption begins below.
        red = Image.new("L", image.size)
        red.putdata([255 if r > 100 and r > g * 1.5 and r > b * 1.5 and a else 0
                     for r, g, b, a in image.getdata()])
        bounds = red.getbbox()
        if bounds is None:
            raise ValueError("NFS source no longer contains its red De badge")
        # Retain the source badge's white lettering; omit the NFS-CHINA text below.
        image = image.crop(bounds)
    else:
        return raw
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()
