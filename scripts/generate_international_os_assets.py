#!/usr/bin/env python3
"""Regenerate international OS artwork from official project/vendor sources.

Uses the same source-colour SVG and 72px RGBA conversion as domestic artwork.
Requires Pillow and resvg-py; see src/ui/assets/host-os/README.md.
"""
import argparse
from pathlib import Path
import urllib.request

from generate_domestic_os_assets import generate

SOURCES = {
    "rhel": "https://www.redhat.com/favicon.ico",
    "centos": "https://www.centos.org/assets/icons/favicon.svg",
    "almalinux": "https://almalinux.org/branding/AlmaLinux%20Icon.svg",
    "oraclelinux": "https://yum.oracle.com/asset/favicons/penguin.ico",
    "sles": "https://www.suse.com/contentassets/17623a922114433cb00cd7bcb7cc6038/favicon.ico",
    "opensuse": "https://static.opensuse.org/favicon.ico",
    "amazonlinux": "https://indico.cern.ch/event/1477299/contributions/6427682/attachments/3044196/5378511/SUSE_hepix_2025.pdf",
    "nixos": "https://nixos.org/favicon.svg",
    "gentoo": "https://www.gentoo.org/assets/img/logo/gentoo-g.png",
    "kali": "https://gitlab.com/kalilinux/documentation/press-pack/-/raw/main/Kali/Logomark_and_Wordmark/kali-logo-dragon-blue.svg",
    "linuxmint": "https://www.linuxmint.com/web/img/favicon.ico",
    "manjaro": "https://manjaro.org/logo.svg",
    "openbsd": "https://www.openbsd.org/favicon.ico",
    "netbsd": "https://www.netbsd.org/images/NetBSD-smaller-tb.png",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Use downloaded NAME.source files")
    parser.add_argument("--only", nargs="+", choices=SOURCES, help="Regenerate only selected OS artwork")
    args = parser.parse_args()
    for name, url in SOURCES.items():
        if args.only and name not in args.only:
            continue
        raw = (args.source_dir / f"{name}.source").read_bytes() if args.source_dir else urllib.request.urlopen(url, timeout=30).read()
        generate(name, raw)
        print(name)


if __name__ == "__main__":
    main()
