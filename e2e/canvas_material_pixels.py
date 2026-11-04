"""Check the final 50% canvas mix in all four cards, not just style alpha.

Uses settings_material_regressions_native.ts's dark theme / 20px checker fixture.
"""
from collections import Counter
import json
import sys

from PIL import Image


with Image.open(sys.argv[1]) as screenshot:
    image = screenshot.convert("RGB")
    scale_x, scale_y = image.width / 1440, image.height / 900
    expected = [tuple(round((base + pixel) / 2) for base, pixel in zip((19, 19, 22), wallpaper))
                for wallpaper in [(242, 192, 65), (71, 129, 232)]]
    samples = []
    regions = [
        ("title", (900, 10, 1200, 35)),
        ("sidebar", (30, 300, 220, 600)),
        ("content", (700, 300, 1000, 600)),
        ("status", (700, 875, 1000, 890)),
    ]
    if len(sys.argv) > 2:
        rect = json.loads(sys.argv[2])
        # The narrow entry lies under the existing title/content shadows.
        # Compare the same checker phase and row beside it, so those shadows
        # remain in both samples; exclude the three foreground dots. The gap
        # uses app RGB (6,6,8), while the card/entry RGB is (19,19,22).
        # Infer shadow attenuation from the adjacent gap and apply it to the
        # same checker phase 40 logical px below, inside the content card.
        matches = total = 0
        for y in range(round((rect["y"] + 1) * scale_y), round((rect["y"] + rect["h"] - 1) * scale_y)):
            for x in range(round((rect["x"] + 8) * scale_x), round((rect["x"] + 42) * scale_x)):
                actual = image.getpixel((x, y))
                adjacent = image.getpixel((x - round(120 * scale_x), y))
                card = image.getpixel((x, y + round(40 * scale_y)))
                delta = [(card_base - app_base) / 2 for card_base, app_base in zip((19, 19, 22), (6, 6, 8))]
                wanted = [adjacent[i] * card[i] / (card[i] - delta[i]) for i in range(3)]
                matches += max(abs(actual[i] - wanted[i]) for i in range(3)) <= 3
                total += 1
        assert matches / total > .95, f"AI entry adds a separate material: {matches}/{total} match the adjacent L0 canvas"
        samples.append({"card": "ai-entry", "matching_canvas_pixels": matches, "total": total})
    for name, bounds in regions:
        region = image.crop(tuple(round(v * (scale_x if i % 2 == 0 else scale_y)) for i, v in enumerate(bounds)))
        raw = region.tobytes()
        colours = Counter(tuple(raw[i:i + 3]) for i in range(0, len(raw), 3))
        # Dominant checker interiors exclude antialiased tile edges and text.
        actual = [colour for colour, _ in colours.most_common(2)]
        assert all(any(max(abs(a - b) for a, b in zip(colour, wanted)) <= 2 for colour in actual)
                   for wanted in expected), (
            f"{name}: final colours {actual}, expected one 50% canvas mix {expected}; "
            "the canvas and card backgrounds must not compound opacity"
        )
        samples.append({"card": name, "actual": actual, "expected": expected})
    print(json.dumps(samples))
