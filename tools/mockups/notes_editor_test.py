#!/usr/bin/env python3
"""Run the notes-editor component probe against a test-mode native build."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


EDITOR = "notes.editor.active"
PREVIEW = "notes.editor.preview"
TAIL = "notes.document.tail"
BINARY = Path(__file__).resolve().parents[2] / "zig-out/bin/mockup-notes-editor"


def request(directory, route, body=None):
    key = uuid.uuid4().hex
    pending = directory / f"req-{key}.tmp"
    response = directory / f"res-{key}.json"
    pending.write_text(json.dumps({
        "method": "GET" if body is None else "POST",
        "path": route,
        "body_json": "" if body is None else json.dumps(body, ensure_ascii=False),
    }, ensure_ascii=False), encoding="utf-8")
    pending.replace(pending.with_suffix(".json"))
    deadline = time.monotonic() + 5
    while not response.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(route)
        time.sleep(0.01)
    try:
        result = json.loads(response.read_text(encoding="utf-8"))
    finally:
        response.unlink()
    assert "error" not in result, (route, result)
    return result


def probe(directory, screenshot):
    def call(route, body=None):
        return request(directory, route, body)

    def node(test_id):
        return call("/query", {"test_id": test_id})[0]

    def key(name, **modifiers):
        assert call("/key_down", {"key": name, **modifiers})["ok"]

    def state():
        return call("/input_state", {"test_id": EDITOR})

    def replace(text):
        key("a", cmd=True)
        assert call("/text_input", {"text": text})["ok"]

    def scroll(x, y, dy, **phases):
        assert call("/scroll", {"x": x, "y": y, "dx": 0, "dy": dy, **phases})["ok"]

    def preview_text():
        return "".join(child.get("text", "") for child in node(PREVIEW).get("children", []))

    def wait_for_preview(expected):
        start = time.monotonic()
        while True:
            rendered = preview_text()
            elapsed = time.monotonic() - start
            if rendered == expected:
                return elapsed
            assert elapsed < 1, (expected, rendered)
            time.sleep(0.02)

    assert call("/health")["status"] == "ok"
    assert call("/click", {"test_id": EDITOR})["ok"]
    key("down", cmd=True)
    scroll(580, 50, 2000)
    editor = node(EDITOR)
    assert (editor["rect"]["w"], editor["rect"]["h"]) == (560, 80)
    assert node(PREVIEW)["rect"]["w"] == 544
    if screenshot:
        assert call("/screenshot", {"path": str(screenshot.resolve())})["ok"]

    plain = "更新配置"
    replace(plain)
    wait_for_preview("")
    code = "，先运行 `nginx -t`"
    assert call("/text_input", {"text": code})["ok"]
    formatted = "更新配置，先运行 nginx -t"
    delay = wait_for_preview(formatted)
    assert state()["buffer"] == plain + code
    assert call("/focused")["id"] == editor["id"]

    assert call("/ime_preedit", {"text": "验证", "cursor_utf8_offset": 6})["ok"]
    assert state()["ime_phase"] == "composing"
    assert state()["buffer"] == plain + code
    assert preview_text() == formatted
    assert call("/ime_commit", {"text": "验证"})["ok"]
    wait_for_preview(formatted + "验证")
    assert state()["buffer"] == plain + code + "验证"
    assert call("/focused")["id"] == editor["id"]

    key("z", cmd=True)
    wait_for_preview(formatted)
    assert state()["buffer"] == plain + code
    key("z", cmd=True, shift=True)
    wait_for_preview(formatted + "验证")
    assert state()["buffer"] == plain + code + "验证"

    long_line = "证书配置更新后的验证与回滚。" * 60
    replace(long_line)
    wait_for_preview("")
    long_state = state()
    assert long_state["buffer"] == long_line and long_state["buffer_len"] == 2520
    assert long_state["display_line_count"] > 4

    long_markdown = "**验证结果**\n\n" + long_line
    replace(long_markdown)
    assert state()["buffer"] == long_markdown
    deadline = time.monotonic() + 1
    while node(TAIL)["rect"]["y"] < 408:
        assert time.monotonic() < deadline, "long preview did not grow"
        time.sleep(0.02)

    # Query geometry without /screen_pos, which can scroll the document itself.
    scroll(580, 50, 2000)
    editor_rect = node(EDITOR)["rect"]
    x = editor_rect["x"] + editor_rect["w"] / 2
    y = editor_rect["y"] + editor_rect["h"] / 2
    tail_at_top = node(TAIL)["rect"]["y"]
    inner_bottom = state()["scroll_y"]
    assert inner_bottom > 40
    scroll(x, y, 40)
    assert state()["scroll_y"] < inner_bottom
    assert node(TAIL)["rect"]["y"] == tail_at_top
    scroll(x, y, -40)
    assert state()["scroll_y"] == inner_bottom
    scroll(x, y, -40)
    assert state()["scroll_y"] == inner_bottom
    after_wheel = node(TAIL)["rect"]["y"]
    assert after_wheel < tail_at_top

    scroll(x, y, 0, phase="began")
    scroll(x, y, -50, phase="changed")
    scroll(x, y, 0, phase="ended")
    assert state()["scroll_y"] == inner_bottom
    assert node(TAIL)["rect"]["y"] < after_wheel
    assert call("/focused")["id"] == editor["id"]
    print(f"Native editor probe passed. Preview update {delay * 1000:.0f} ms after input acknowledgement.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshot", type=Path, help="Optional native compact editor capture")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="zw-notes-editor-") as temporary:
        directory = Path(temporary)
        env = {
            **os.environ,
            "ZENIT_E2E_FILE_RPC_DIR": str(directory),
            "ZENIT_E2E_ISOLATE_POINTER": "1",
            "ZENIT_E2E_ISOLATE_KEYBOARD": "1",
        }
        log_path = directory / "native.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen([BINARY], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                probe(directory, args.screenshot)
            finally:
                if process.poll() is None:
                    try:
                        assert request(directory, "/quit", {})["ok"]
                        assert process.wait(timeout=5) == 0
                    except (AssertionError, TimeoutError, subprocess.TimeoutExpired):
                        if process.poll() is None:
                            process.terminate()
                            process.wait(timeout=5)
                        raise


if __name__ == "__main__":
    main()
