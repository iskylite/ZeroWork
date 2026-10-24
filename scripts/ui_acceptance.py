#!/usr/bin/env python3
"""Validate the 47-scene UI acceptance ledger and reproducible evidence.

This tool is an evidence-structure gate only. It never marks a scene passed and
never treats a successful build or unit test as visual/CUA acceptance.
"""
import argparse
import hashlib
import json
import re
import struct
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT / "docs/DEVELOPMENT/UI_ACCEPTANCE.json"
EVIDENCE_ROOT = Path("dist/ui-acceptance")
REQUIRED_MANIFEST_KEYS = {
    "built_at", "entry_point", "bundle_identifier", "binary_sha256",
    "unsigned_source_sha256", "copy_verified_before_signing",
}
EVIDENCE_KEYS = ("capture", "diff", "geometry_report", "interaction_record", "build_manifest")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size(path):
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"Not PNG: {path}")
    return list(struct.unpack(">II", data[16:24]))


def repo_path(value, scene, field):
    """Resolve an evidence path without allowing absolute/traversal paths."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{scene}: {field} must be a non-empty relative path")
    candidate = Path(value)
    if candidate.is_absolute():
        raise ValueError(f"{scene}: {field} must be relative to repository")
    resolved = (ROOT / candidate).resolve()
    try:
        resolved.relative_to(ROOT.resolve())
    except ValueError:
        raise ValueError(f"{scene}: {field} escapes repository")
    return candidate, resolved


def evidence_path(value, scene, field):
    candidate, resolved = repo_path(value, scene, field)
    try:
        candidate.relative_to(EVIDENCE_ROOT)
    except ValueError:
        raise ValueError(f"{scene}: {field} must live under {EVIDENCE_ROOT}/")
    if not resolved.is_file():
        raise ValueError(f"{scene}: missing evidence {field}: {value}")
    return candidate, resolved


def iso_timestamp(value):
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def validate_manifest(path, scene, errors):
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"{scene}: build_manifest is not valid JSON ({exc})")
        return
    if not isinstance(manifest, dict):
        errors.append(f"{scene}: build_manifest must contain a JSON object")
        return
    missing = REQUIRED_MANIFEST_KEYS - set(manifest)
    if missing:
        errors.append(f"{scene}: build_manifest missing {', '.join(sorted(missing))}")
    if manifest.get("bundle_identifier") != "com.zerowork.uicheck":
        errors.append(f"{scene}: build_manifest has wrong bundle_identifier")
    if manifest.get("entry_point") != "src/main.zig":
        errors.append(f"{scene}: build_manifest entry_point must be src/main.zig")
    if manifest.get("copy_verified_before_signing") is not True:
        errors.append(f"{scene}: build_manifest copy_verified_before_signing must be true")
    for key in ("binary_sha256", "unsigned_source_sha256"):
        if key in manifest and (not isinstance(manifest[key], str) or not re.fullmatch(r"[0-9a-f]{64}", manifest[key])):
            errors.append(f"{scene}: build_manifest {key} must be a lowercase SHA-256")
    if "built_at" in manifest and not iso_timestamp(manifest["built_at"]):
        errors.append(f"{scene}: build_manifest built_at must be ISO-8601")


def init():
    if LEDGER.exists():
        raise SystemExit("Ledger already exists; refusing to overwrite review evidence.")
    plan = (ROOT / "docs/DEVELOPMENT/UI_IMPLEMENTATION_PLAN.md").read_text()
    rows = re.findall(r"^\| (\d\d) \| ([\w-]+) \| ([^|]+) \| ([^|]+) \|$", plan, re.M)
    assert len(rows) == 47, f"Expected 47 plan rows, got {len(rows)}"
    scenes = []
    for number, name, trigger, owner in rows:
        png = Path(f"docs/SPEC/mockups/mockup-{name}.png")
        html = Path(f"docs/SPEC/html/mockup-{name}.html")
        scenes.append({
            "id": int(number), "name": name, "owner": owner.strip(), "trigger": trigger.strip(),
            "reference_png": str(png), "reference_html": str(html),
            "png_sha256": sha(ROOT / png), "html_sha256": sha(ROOT / html),
            "reference_pixels": png_size(ROOT / png), "status": "pending",
            "production_entry": None, "fixture_description": None, "semantic_notes": None,
            "capture": None, "diff": None, "geometry_report": None,
            "interaction_record": None, "build_manifest": None, "reviewer": None,
            "reviewed_at": None, "remaining_issues": [],
        })
    LEDGER.write_text(json.dumps({"schema_version": 1, "scenes": scenes}, ensure_ascii=False, indent=2) + "\n")


def check(require_complete, report_path=None):
    errors = []
    try:
        ledger = json.loads(LEDGER.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Cannot read ledger: {exc}")
        return 1
    scenes = ledger.get("scenes", [])
    baseline = json.loads((ROOT / "docs/DEVELOPMENT/UI_BASELINE.json").read_text())
    for item in baseline["files"]:
        try:
            if sha(ROOT / item["path"]) != item["sha256"]:
                errors.append(f"Original design changed: {item['path']}")
        except OSError:
            errors.append(f"Original design missing: {item['path']}")
    expected = {p.stem.removeprefix("mockup-") for p in (ROOT / "docs/SPEC/mockups").glob("mockup-*.png")}
    if len(scenes) != 47 or {s.get("name") for s in scenes} != expected or len({s.get("id") for s in scenes}) != 47:
        errors.append("Ledger must cover every original scene once (47 scenes).")
    passed = 0
    for s in scenes:
        name = s.get("name", "<unnamed>")
        for key, hashkey in (("reference_png", "png_sha256"), ("reference_html", "html_sha256")):
            try:
                if sha(ROOT / s[key]) != s[hashkey]: errors.append(f"{name}: {key} changed")
            except (KeyError, OSError): errors.append(f"{name}: missing {key}")
        try:
            if png_size(ROOT / s["reference_png"]) != s["reference_pixels"]:
                errors.append(f"{name}: reference dimensions changed")
        except (KeyError, OSError, ValueError): errors.append(f"{name}: invalid reference PNG")
        status = s.get("status")
        if status not in ("pending", "blocked", "failed", "passed"):
            errors.append(f"{name}: invalid status")
        if status != "passed":
            continue
        passed += 1
        for key in ("production_entry", "fixture_description", "semantic_notes", "reviewer", "reviewed_at"):
            if not isinstance(s.get(key), str) or not s[key].strip(): errors.append(f"{name}: missing {key}")
        if not iso_timestamp(s.get("reviewed_at")):
            errors.append(f"{name}: reviewed_at must be ISO-8601")
        notes = str(s.get("semantic_notes", ""))
        if len(notes) < 20 or not re.search(r"(HTML|SPEC|DESIGN|标注|说明|状态|控件)", notes, re.I):
            errors.append(f"{name}: semantic_notes must explain UI/annotation/state semantics with source evidence")
        entry = str(s.get("production_entry", ""))
        if re.search(r"mockup|preview|独立", entry, re.I): errors.append(f"{name}: production_entry points to mockup/preview")
        issues = s.get("remaining_issues")
        if not isinstance(issues, list): errors.append(f"{name}: remaining_issues must be an array")
        elif issues: errors.append(f"{name}: passed with unresolved issues")
        resolved = {}
        for key in EVIDENCE_KEYS:
            try:
                _, resolved[key] = evidence_path(s.get(key), name, key)
            except ValueError as exc:
                errors.append(str(exc))
        if "capture" in resolved:
            try:
                if png_size(resolved["capture"]) != s["reference_pixels"]: errors.append(f"{name}: production crop dimensions differ from original")
                if resolved["capture"].suffix.lower() != ".png": errors.append(f"{name}: capture must be PNG")
                if resolved["capture"] == (ROOT / s.get("reference_png")).resolve(): errors.append(f"{name}: capture cannot be reference PNG")
            except (ValueError, KeyError): errors.append(f"{name}: capture is not a valid PNG")
        if "diff" in resolved:
            try:
                if resolved["diff"].suffix.lower() == ".png" and png_size(resolved["diff"]) != s["reference_pixels"]: errors.append(f"{name}: diff PNG dimensions differ from original")
            except ValueError: errors.append(f"{name}: diff is not a valid PNG")
        if "geometry_report" in resolved:
            try:
                report = json.loads(resolved["geometry_report"].read_text())
                if not isinstance(report, dict) or not {"reference_pixels", "capture_pixels", "verdict"} <= set(report): errors.append(f"{name}: geometry_report missing reference_pixels/capture_pixels/verdict")
                elif report["reference_pixels"] != s["reference_pixels"] or report["capture_pixels"] != s["reference_pixels"]: errors.append(f"{name}: geometry_report dimensions do not match ledger")
            except (OSError, json.JSONDecodeError): errors.append(f"{name}: geometry_report must be valid JSON")
        if "build_manifest" in resolved: validate_manifest(resolved["build_manifest"], name, errors)
    result = {"passed": passed, "total": 47, "errors": errors}
    if report_path:
        Path(report_path).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"Formal acceptance: {passed}/47 passed; {len(errors)} evidence errors.")
    for error in errors: print(error)
    return 1 if errors or (require_complete and passed != 47) else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--init", action="store_true")
    parser.add_argument("--require-complete", action="store_true")
    parser.add_argument("--report", metavar="PATH", help="write a machine-readable audit report")
    args = parser.parse_args()
    if args.init: init()
    raise SystemExit(check(args.require_complete, args.report))
