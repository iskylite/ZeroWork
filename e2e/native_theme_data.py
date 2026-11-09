"""Read the theme values used by native screenshot checks from application code."""

import json
import pathlib
import re


def _color(value):
    value = value.lower()
    return "#" + (value[:6] if value.endswith("ff") else value)


def load():
    source = (pathlib.Path(__file__).resolve().parents[1] / "src/config/theme_presets.zig").read_text()
    token_source = source.split("pub fn tokens", 1)[1].split("pub fn ansi", 1)[0]
    defaults_source = source.split("pub fn terminalDefaults", 1)[1]
    pattern = r'if \(std\.mem\.eql\(u8, id, "([^"]+)"\)\) return \.\{(.*?)\};'
    fields = r'\.(\w+) = 0x([\da-fA-F]{8})'
    themes = {
        theme: {"--" + role.replace("_", "-"): _color(value) for role, value in re.findall(fields, body)}
        for theme, body in re.findall(pattern, token_source, re.S)
    }
    terminals = {
        theme: {role: _color(value) for role, value in re.findall(fields, body)}
        for theme, body in re.findall(pattern, defaults_source, re.S)
    }
    if not themes or themes.keys() != terminals.keys():
        raise ValueError("Native theme and terminal defaults are incomplete")
    return {"themes": themes, "terminalPalettes": terminals}


if __name__ == "__main__":
    print(json.dumps(load()))
