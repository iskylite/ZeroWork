"""Opt-in real gateway vision acceptance; uses only Python's standard library.

python3 e2e/ai_provider_image_live.py /tmp/zerowork-provider-image-live
Generates new random pixels/labels, records direct model behavior, then checks
declared vision models through the production native client and tool loop.
Only local gateway test authentication is supplied by default.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import urllib.error
import urllib.request
import zlib


GLYPHS = {
    "0": [14, 17, 19, 21, 25, 17, 14], "1": [4, 12, 4, 4, 4, 4, 14],
    "2": [14, 17, 1, 2, 4, 8, 31], "3": [30, 1, 1, 14, 1, 1, 30],
    "4": [2, 6, 10, 18, 31, 2, 2], "5": [31, 16, 16, 30, 1, 1, 30],
    "6": [14, 16, 16, 30, 17, 17, 14], "7": [31, 1, 2, 4, 8, 8, 8],
    "8": [14, 17, 17, 14, 17, 17, 14], "9": [14, 17, 17, 15, 1, 1, 14],
    "A": [14, 17, 17, 31, 17, 17, 17], "B": [30, 17, 17, 30, 17, 17, 30],
    "C": [15, 16, 16, 16, 16, 16, 15], "D": [30, 17, 17, 17, 17, 17, 30],
    "E": [31, 16, 16, 30, 16, 16, 31], "F": [31, 16, 16, 30, 16, 16, 16],
}
PROMPT = ("Inspect the attached image pixels. Return only a JSON object with keys "
          "top_left, top_right, bottom_left, bottom_right, each containing color "
          "(one of red, green, blue, yellow) and text (the exact six visible "
          "characters). Do not guess; if the image is unavailable say IMAGE_UNAVAILABLE.")


def challenge(folder):
    width, height, scale = 960, 640, 8
    pixels = bytearray([255]) * (width * height * 3)

    def rect(x, y, w, h, rgb):
        row = bytes(rgb) * w
        for yy in range(y, y + h):
            start = (yy * width + x) * 3
            pixels[start:start + len(row)] = row

    colors = ["red", "green", "blue", "yellow"]
    secrets.SystemRandom().shuffle(colors)
    rgb = {"red": (237, 59, 59), "green": (43, 191, 88),
           "blue": (55, 117, 238), "yellow": (243, 204, 53)}
    expected = {}
    for index, position in enumerate(["top_left", "top_right", "bottom_left", "bottom_right"]):
        text = secrets.token_hex(3).upper()
        x, y = (index % 2) * 480, (index // 2) * 320
        rect(x + 16, y + 16, 448, 288, rgb[colors[index]])
        rect(x + 80, y + 112, 320, 96, (255, 255, 255))
        for column, char in enumerate(text):
            for row, pattern in enumerate(GLYPHS[char]):
                for bit in range(5):
                    if pattern & (1 << (4 - bit)):
                        rect(x + 100 + column * 48 + bit * scale, y + 132 + row * scale,
                             scale, scale, (0, 0, 0))
        expected[position] = {"color": colors[index], "text": text}

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    (folder / "challenge.png").write_bytes(png)
    manifest = {"image_sha256": hashlib.sha256(png).hexdigest(), "expected": expected}
    (folder / "challenge.json").write_text(json.dumps(manifest, indent=2))
    return png, manifest


def request(gateway, path, body=None):
    headers = {"Authorization": "Bearer " + os.getenv("ZEROWORK_AI_GATEWAY_KEY", "local-gateway")}
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(gateway.rstrip("/") + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=150) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        raw = error.read().decode()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"error": "Non-JSON gateway response"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--gateway", default="http://127.0.0.1:3425/v1")
    parser.add_argument("--model", action="append", dest="models")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    png, manifest = challenge(args.output)
    status, catalog = request(args.gateway, "/models")
    if status != 200:
        raise RuntimeError(f"Model discovery failed: HTTP {status}")
    models = args.models or ["codex/gpt-6.1-sol", "auto/glm-5.3"]
    entries = {entry["id"]: entry for entry in catalog["data"] if entry["id"] in models}
    report = {"models_endpoint_status": status, "challenge": manifest, "results": []}
    failed = False
    for model in models:
        entry = entries.get(model)
        if entry is None:
            raise RuntimeError("Requested model not discovered: " + model)
        model_dir = args.output / model.replace("/", "-")
        model_dir.mkdir(exist_ok=True)
        declared_vision = "image" in entry.get("modalities", {}).get("input", [])
        status, response = request(args.gateway, "/chat/completions", {
            "model": model, "stream": False, "max_tokens": 2048,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {
                    "url": "data:image/png;base64," + base64.b64encode(png).decode(), "detail": "high"}},
            ]}],
        })
        message = response.get("choices", [{}])[0].get("message", {})
        answer = message.get("content", "")
        try:
            actual = json.loads(answer.strip().removeprefix("```json").removesuffix("```").strip())
        except (ValueError, AttributeError):
            actual = None
        semantic_match = actual == manifest["expected"]
        result = {"model": model, "declared_vision": declared_vision, "direct_http_status": status,
                  "direct_semantics_match": semantic_match, "answer": answer,
                  "metadata": entry, "native_tool_test": "not_run_undeclared_vision",
                  "native_vision_verified": False}
        # Preserve the real response for capability diagnosis; request image bytes and
        # request headers are never written to logs or reports.
        (model_dir / "direct-response.json").write_text(json.dumps(response, indent=2))
        if declared_vision:
            native_evidence = model_dir / "native-tool.json"
            env = {**os.environ, "ZEROWORK_AI_GATEWAY_TEXT_LIVE": "0",
                   "ZEROWORK_AI_GATEWAY_LIVE": "1",
                   "ZEROWORK_AI_GATEWAY_KEY": os.getenv("ZEROWORK_AI_GATEWAY_KEY", "local-gateway"),
                   "ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT": args.gateway.rstrip("/") + "/chat/completions",
                   "ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT": args.gateway.rstrip("/") + "/models",
                   "ZEROWORK_AI_GATEWAY_MODEL": model,
                   "ZEROWORK_AI_GATEWAY_IMAGE_FIXTURE": str(args.output / "challenge.png"),
                   "ZEROWORK_AI_GATEWAY_IMAGE_MANIFEST": str(args.output / "challenge.json"),
                   "ZEROWORK_AI_GATEWAY_EVIDENCE": str(native_evidence)}
            with (model_dir / "native-test.log").open("w") as log:
                test = subprocess.run(["zig", "build", "test-ai-gateway"], env=env,
                                      cwd=Path(__file__).resolve().parents[1], stdout=log,
                                      stderr=subprocess.STDOUT, timeout=240, check=False)
            native = json.loads(native_evidence.read_text()) if native_evidence.exists() else None
            result["native_tool_test"] = "passed" if test.returncode == 0 else "failed"
            result["native_evidence"] = native
            result["native_vision_verified"] = test.returncode == 0 and semantic_match
            failed |= test.returncode != 0 or not semantic_match
        report["results"].append(result)
        (args.output / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({key: value for key, value in result.items()
                          if key not in ["metadata", "native_evidence"]}), flush=True)
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
