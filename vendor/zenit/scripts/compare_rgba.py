#!/usr/bin/env python3
"""Compare matching PNGs exactly, including alpha. Requires Pillow."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageChops


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--diff-dir", type=Path)
    args = parser.parse_args()
    files = sorted(args.before.glob("*.png"))
    if not files:
        parser.error("before directory contains no PNG files")
    results = []
    for before in files:
        after = args.after / before.name
        if not after.exists():
            parser.error(f"missing comparison image: {after}")
        with Image.open(before) as a, Image.open(after) as b:
            a, b = a.convert("RGBA"), b.convert("RGBA")
            if a.size != b.size:
                results.append(dict(file=before.name, before_size=a.size, after_size=b.size, equal=False))
                continue
            diff = ImageChops.difference(a, b)
            mask = diff.getchannel("R")
            for channel in "GBA":
                mask = ImageChops.lighter(mask, diff.getchannel(channel))
            changed = sum(value != 0 for value in mask.tobytes())
            results.append(dict(file=before.name, size=a.size, changed_pixels=changed, bounds=mask.getbbox(), equal=changed == 0))
            if args.diff_dir:
                args.diff_dir.mkdir(parents=True, exist_ok=True)
                diff.convert("RGB").save(args.diff_dir / before.name)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(results, indent=2) + "\n")
    for row in results:
        print(f"{row['file']}: {row.get('changed_pixels', 'size mismatch')} changed pixels")
    return 0 if all(row["equal"] for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
