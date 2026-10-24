#!/usr/bin/env python3
"""Reject App binaries that still contain product/automation environment controls."""
import hashlib
import json
import pathlib
import re
import sys

binary = pathlib.Path(sys.argv[1]).resolve()
data = binary.read_bytes()
names = set(re.findall(rb"\b(?:ZEROWORK|ZENIT)_[A-Z][A-Z0-9_]{2,}\b", data))
# Embedded Metal source uses this compile-time macro; it never reads an environment.
shader_macros = {b"ZENIT_FRAMEBUFFER_FETCH"}
for name in (b"OPENAI_API_KEY", b"ANTHROPIC_API_KEY", b"ZW_EDIT_FD", b"ZW_EDIT_PARENT"):
    if name in data:
        names.add(name)
forbidden = sorted(name.decode() for name in names - shader_macros)
print(json.dumps({
    "binary": str(binary), "sha256": hashlib.sha256(data).hexdigest(),
    "forbidden_environment_identifiers": forbidden,
    "shader_macros": sorted(name.decode() for name in names & shader_macros),
    "status": "failed" if forbidden else "passed",
}, indent=2))
if forbidden:
    raise SystemExit("Formal App still contains environment controls or test instrumentation")
