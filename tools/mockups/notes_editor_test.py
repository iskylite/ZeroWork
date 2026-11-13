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

    def rendered_lines(node):
        if node.get("visible") is False or node.get("rect", {}).get("h", 0) == 0:
            return []
        return [node.get("text", "")] + [
            text for child in node.get("children", []) for text in rendered_lines(child)
        ]

    def wait_for_line(expected):
        start = time.monotonic()
        while True:
            rendered = rendered_lines(node(EDITOR))
            if expected in rendered:
                return
            assert time.monotonic() - start < 1, (expected, rendered)
            time.sleep(0.02)

    assert call("/health")["status"] == "ok"
    assert call("/click", {"test_id": EDITOR})["ok"]
    key("down", cmd=True)
    editor = node(EDITOR)
    assert (editor["rect"]["w"], editor["rect"]["h"]) == (560, 78)

    source = "更新配置，先运行 `nginx -t`"
    replace(source)
    wait_for_line("更新配置，先运行 nginx -t")
    assert call("/text_input", {"text": "\n待验证"})["ok"]
    wait_for_line("更新配置，先运行 nginx -t")
    assert state()["buffer"] == source + "\n待验证"
    assert call("/focused")["id"] == editor["id"]

    assert call("/ime_preedit", {"text": "验证", "cursor_utf8_offset": 6})["ok"]
    assert state()["ime_phase"] == "composing"
    assert state()["buffer"] == source + "\n待验证"
    assert call("/ime_commit", {"text": "通过"})["ok"]
    wait_for_line("待验证通过")

    key("z", cmd=True)
    wait_for_line("待验证")
    key("z", cmd=True, shift=True)
    wait_for_line("待验证通过")

    for marker in ("-", "*", "+"):
        replace(marker)
        wait_for_line(marker)
        assert call("/text_input", {"text": " "})["ok"]
        wait_for_line("• ")
        assert state()["buffer"] == marker + " "
        assert call("/text_input", {"text": "列表项"})["ok"]
        wait_for_line("• 列表项")
        key("return")
        wait_for_line("• ")
        assert state()["buffer"] == f"{marker} 列表项\n{marker} "
        key("return")
        assert state()["buffer"] == f"{marker} 列表项\n"

    for prefix, suffix, rendered in [
        (">", " 引用", "▏ 引用"),
        ("#", " 标题", "标题"),
        ("- [x", "]", "☑"),
        ("**强调*", "*", "强调"),
        ("~~删除~", "~", "删除"),
        ("[链接](doc", ")", "链接"),
        ("1.", " 有序项", "1. 有序项"),
        ("```sh\n-", " echo", "- echo"),
    ]:
        replace(prefix)
        assert call("/text_input", {"text": suffix})["ok"]
        wait_for_line(rendered)
        assert state()["buffer"] == prefix + suffix
        key("z", cmd=True)
        assert state()["buffer"] == prefix

    # Select across paragraph boundaries with the same keyboard target.
    replace("甲段\n\n**乙段**\n丙段")
    key("up", cmd=True)
    for _ in range(3):
        key("down", shift=True)
    assert call("/text_input", {"text": "合并后的段落\n"})["ok"]
    assert state()["buffer"] == "合并后的段落\n丙段", state()
    key("z", cmd=True)
    assert state()["buffer"] == "甲段\n\n**乙段**\n丙段"
    key("z", cmd=True, shift=True)
    assert state()["buffer"] == "合并后的段落\n丙段"

    replace("9. 第九项\n10. 现有项")
    key("up", cmd=True)
    key("right", cmd=True)
    key("return")
    assert state()["buffer"] == "9. 第九项\n10. \n11. 现有项", state()
    key("return")
    assert state()["buffer"] == "9. 第九项\n\n10. 现有项"
    key("z", cmd=True)
    key("z", cmd=True)
    assert state()["buffer"] == "9. 第九项\n10. 现有项"

    for previous, suffix in [
        ("# 1. 你好", "\n"),
        ("## 1.9 核对配置", "\n"),
        ("# 2. ", "\n"),
        ("- [x] 已完成", "\n- [ ] "),
        ("> 引用", "\n> "),
        ("```sh\n1. echo example", "\n"),
        ("# 2026 运维记录", "\n"),
    ]:
        replace(previous)
        key("return")
        assert state()["buffer"] == previous + suffix, state()

    source = "# 1. 你好"
    replace(source)
    key("return")
    assert call("/text_input", {"text": "正文"})["ok"]
    key("return")
    assert call("/text_input", {"text": "#"})["ok"]
    assert state()["buffer"] == source + "\n正文\n#"
    assert call("/text_input", {"text": " "})["ok"]
    assert state()["buffer"] == source + "\n正文\n# 2. "
    assert call("/text_input", {"text": "我也是"})["ok"]
    wait_for_line("2. 我也是")
    key("return")
    wait_for_line("2. 我也是")
    assert state()["buffer"] == source + "\n正文\n# 2. 我也是\n"

    for previous, prefix, numbered in [
        ("## 1.9 核对配置", "##", " 1.10 "),
        ("## 1.9 核对配置", "#", " "),
        ("# 第一章\n## 1.9 核对配置\n# 第二章", "##", " "),
        ("# 概览", "#", " "),
        ("# 1. 概览\n```sh\n# 9. 字面内容\n```", "#", " 2. "),
        ("# 1. 概览\n```sh", "#", " "),
    ]:
        replace(previous)
        key("return")
        assert call("/text_input", {"text": prefix})["ok"]
        assert call("/text_input", {"text": " "})["ok"]
        assert state()["buffer"] == previous + "\n" + prefix + numbered, state()
        key("z", cmd=True)
        assert state()["buffer"] == previous + "\n" + prefix, state()

    replace("[] 待核对\n[x] 已核对")
    wait_for_line("☐ 待核对")
    wait_for_line("☑ 已核对")
    key("return")
    assert state()["buffer"] == "[] 待核对\n[x] 已核对\n[ ] "

    # Fenced code keeps its original text, indentation and blank line.
    replace("~~~sh\n  echo first\n\n  echo second\n~~~")
    key("up", cmd=True)
    wait_for_line("  echo first")
    assert state()["buffer"] == "~~~sh\n  echo first\n\n  echo second\n~~~"

    long_line = "证书配置更新后的验证与回滚。" * 60
    replace(long_line)
    long_state = state()
    assert long_state["buffer"] == long_line and long_state["buffer_len"] == 2520
    assert long_state["display_line_count"] > 4

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
    assert after_wheel <= tail_at_top

    scroll(x, y, 0, phase="began")
    scroll(x, y, -50, phase="changed")
    scroll(x, y, 0, phase="ended")
    assert state()["scroll_y"] == inner_bottom
    assert node(TAIL)["rect"]["y"] <= after_wheel
    assert call("/focused")["id"] == editor["id"]
    print("Native editor probe passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=BINARY)
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
            process = subprocess.Popen([args.binary], env=env, stdout=log, stderr=subprocess.STDOUT)
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
