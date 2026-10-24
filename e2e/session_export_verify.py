#!/usr/bin/env python3
"""Read-only checks for real live-session exports made through NSSavePanel.

Reuse native_input.ts and ssh_aux_download_loopback.py for the actual UI and
SSH session. This checker never starts an app, connects, grants a picker
receipt, creates a recording or writes into the selected output directory.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re


def text_payload(data):
    payload = bytearray()
    count = 0
    for line in data.decode("ascii").splitlines():
        match = re.fullmatch(r"\[(-?\d+)\] offset=(\d+) (.*)", line)
        assert match, "Not a live Timeline text record"
        assert int(match[2]) == len(payload), "Missing, duplicated or reordered stream bytes"
        escaped = match[3]
        index = 0
        while index < len(escaped):
            if escaped[index] != "\\":
                payload.append(ord(escaped[index]))
                index += 1
                continue
            index += 1
            assert index < len(escaped), "Truncated Timeline escape"
            token = escaped[index]
            if token == "x":
                byte = escaped[index + 1:index + 3]
                assert re.fullmatch(r"[0-9a-fA-F]{2}", byte), "Invalid Timeline byte escape"
                payload.append(int(byte, 16))
                index += 3
            else:
                assert token in "nrt\\", "Unexpected Timeline escape"
                payload.append({"n": 10, "r": 13, "t": 9, "\\": 92}[token])
                index += 1
        count += 1
    assert count > 0, "Empty live Timeline"
    return bytes(payload), {"events": count, "kind": "escaped_live_timeline"}


def cast_payload(data):
    lines = data.decode("utf-8").splitlines()
    header = json.loads(lines[0])
    assert header["version"] == 2
    for key in ("width", "height"):
        assert type(header[key]) is int and 0 < header[key] <= 1000
    payload = bytearray()
    previous = 0
    count = 0
    for line in lines[1:]:
        event = json.loads(line)
        assert isinstance(event, list) and len(event) == 3
        seconds, kind, output = event
        assert type(seconds) in (int, float) and math.isfinite(seconds) and previous <= seconds
        assert kind == "o" and isinstance(output, str)
        previous = seconds
        payload.extend(output.encode("utf-8"))
        count += 1
    assert count > 0, "Empty asciicast"
    return bytes(payload), {"events": count, "kind": "asciicast_v2", "width": header["width"], "height": header["height"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--format", choices=("txt", "cast", "txt_cast"), required=True)
    parser.add_argument("--phase", choices=("cancelled", "saved"), required=True)
    parser.add_argument("--stem", default="Original Capture")
    parser.add_argument("--exclude-token", required=True, help="Unique text printed only in the other Local tab")
    args = parser.parse_args()
    assert args.stem and Path(args.stem).name == args.stem
    directory = args.directory.resolve(strict=True)
    assert directory.is_dir()
    ready = json.loads(args.ready.read_text())
    sentinel = ready["clipboard_sentinel"]
    assert re.fullmatch(r"ZW_CLIP_SSH_[0-9a-f]{12}", sentinel)
    expected = ("ZW_AUX_SOURCE_READY\r\n" + sentinel +
                "\r\n\x1b]7;file://localhost/fixture\x07fixture@loopback:/fixture $ ").encode("ascii")
    assert args.exclude_token and args.exclude_token.encode() not in expected
    kinds = ("txt", "cast") if args.format == "txt_cast" else (args.format,)
    expected_names = [] if args.phase == "cancelled" else sorted(f"{args.stem}.{kind}" for kind in kinds)
    assert sorted(path.name for path in directory.iterdir()) == expected_names, "Unexpected, missing or partial export file"
    files = []
    for kind in kinds if args.phase == "saved" else ():
        path = directory / f"{args.stem}.{kind}"
        assert path.is_file() and not path.is_symlink()
        data = path.read_bytes()
        payload, facts = text_payload(data) if kind == "txt" else cast_payload(data)
        assert payload == expected, "Export bytes do not match the original SSH owner's exact incoming stream"
        assert args.exclude_token.encode() not in payload, "Another tab's output leaked into this export"
        files.append({"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), **facts})
    print(json.dumps({"status": "passed", "scope": "read_only_live_export_files", "phase": args.phase,
                      "format": args.format, "directory": str(directory), "files": files,
                      "expected_stream_bytes": len(expected), "original_peer_sentinel": sentinel,
                      "other_tab_token_excluded": args.exclude_token, "native_picker_verified": False}, indent=2))


if __name__ == "__main__":
    main()
