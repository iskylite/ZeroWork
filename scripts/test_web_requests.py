#!/usr/bin/env python3
"""Exercise bounded WebKit callbacks, host replies and cancellation lifetimes."""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="zerowork-web-requests-") as directory:
        binary = Path(directory) / "web-request-probe"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
            "-mmacosx-version-min=13.0", "-DZW_WEB_SURFACE_HEADLESS=1", "-DZW_WEB_SURFACE_ACCEPTANCE=1",
            "-DZW_WEB_REQUEST_LIFETIME_NS=100000000", "-framework", "AppKit", "-framework", "WebKit",
            "-framework", "Network", "-framework", "QuartzCore", str(root / "e2e/web_request_probe.m"),
            str(root / "src/platform/macos_web_surface.m"), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
