"""Check actual glyph ink inside the exact captured history row rectangles."""
import json
import math
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

root = Path(sys.argv[1])
cases = [
    ("dark-manifest-command", "dark"),
    ("dark-manifest-theme-light", "light"),
    ("dark-manifest-theme-sauber", "sauber"),
    ("dark-manifest-theme-dark", "dark"),
    ("light-manifest-command", "light"),
    ("sauber-manifest-command", "sauber"),
]
# Terminal colors follow ThemeRegistry.builtinTheme / theme_presets.ansi,
# independently of the UI chrome inks. Sauber publishes blue default VT ink.
foreground = {"dark": (244, 244, 245), "light": (24, 24, 27), "sauber": (19, 69, 246)}
indexed_red = {"dark": (243, 114, 114), "light": (195, 34, 34), "sauber": (173, 60, 50)}
literal_rgb = (232, 121, 249)
report = []
for name, theme in cases:
    tree = json.loads((root / f"{name}.tree.json").read_text())
    image = Image.open(root / f"{name}.png").convert("RGB")
    scale = image.width / 860
    assert scale == image.height / 480 == 2, (name, image.size)

    def pixels(needle):
        node = next(n for n in tree["terminal.row"] if needle in n.get("text", ""))
        r = node["rect"]
        crop = image.crop((math.floor(r["x"] * scale), math.floor(r["y"] * scale),
                           math.ceil((r["x"] + r["w"]) * scale), math.ceil((r["y"] + r["h"]) * scale)))
        return Counter(crop.get_flattened_data())

    defaults = pixels("LOCAL_ARCHIVE_DEFAULT")
    styled = pixels("ANSI_RED")
    counts = {"global_default": defaults[foreground[theme]],
              "global_indexed": styled[indexed_red[theme]],
              "literal_rgb": styled[literal_rgb]}
    assert all(value > 25 for value in counts.values()), (name, theme, counts)
    background = defaults.most_common(1)[0][0]
    assert background != (16, 16, 24), (name, "manifest background was restored")
    report.append({"capture": name, "theme": theme, "counts": counts,
                   "default_rgb": foreground[theme], "indexed_rgb": indexed_red[theme],
                   "literal_rgb": literal_rgb, "background_rgb": background})
print(json.dumps(report, indent=2))
