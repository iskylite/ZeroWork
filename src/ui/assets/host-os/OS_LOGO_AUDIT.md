# OS logo audit — 2026-11-03

Scope: the 11 entries previously marked “厂商” or “待核对” in the preview.
The accepted rule is to prefer the distribution's own mark; recognizable
conventional/shared marks are also allowed. A company favicon alone is not
evidence that the image represents its operating system.

| OS | Decision and artwork | Evidence |
| --- | --- | --- |
| macOS | Keep the conventional Apple silhouette. No Finder/app icon or version-specific installer badge is substituted. | Existing app asset `../local_apple.svg`; retained under the user's explicit allowance for conventional marks. |
| RHEL | Keep the familiar red hat under the user’s explicit preference for this recognizable shared product/brand mark. | [Official Red Hat logo guidance](https://www.redhat.com/en/about/brand/standards/logo); the standalone graphic comes from the [official favicon](https://www.redhat.com/favicon.ico). |
| SUSE Linux Enterprise | Keep the chameleon, which is shared with the product identity. | [SUSE's own HEPIX presentation](https://indico.cern.ch/event/1477299/contributions/6427682/attachments/3044196/5378511/SUSE_hepix_2025.pdf), page 12, shows the chameleon in the SUSE Linux Enterprise Server product lockup. The existing asset comes from SUSE's site. |
| Amazon Linux | Replace the AWS wordmark with the conventional Amazon Linux penguin. This is a conventional distribution illustration, not claimed to be an official independent AWS logo. | Same SUSE/Uyuni presentation, page 12, embeds the Amazon `a`/smile penguin alongside its supported Amazon Linux 2 distribution. |
| NeoKylin | Replace the KylinSoft company wordmark with the red qilin product figure. | The vendor-authored [NeoKylin V7 installation manual](https://mkp-res.hc-cdn.com/marketplace/public/app/attachment/20230307/8fde8b2c-9176-4d98-b403-9dd460952db5/934fdcfa-e2e2-4a1d-94d3-02a39bbada95.pdf), PDF page 9, shows this red qilin in the installer. The [official product page archived in 2022](https://web.archive.org/web/20220204000000id_/https://www.kylinos.cn/scheme/server/9.html) also identifies the product. The usable raster is a [secondary reproduction](https://p3-sdbk2-media.byteimg.com/tos-cn-i-xv4ileqgde/d9fb1b4ea2554a70baa0ac24db8f2f51~tplv-xv4ileqgde-resize-w:720.image), visually cross-checked against that installer; it is not presented as a newly obtained official master. |
| EulerOS | Use the flower from EulerOS's own system logo package, omitting the HUAWEI wordmark. The vendor and distribution share this shape. | [Huawei's EulerOS repository package](https://mirrors.huaweicloud.com/euler/2.0/os/x86_64/Packages/euleros-logos-2.0-6.noarch.rpm), `usr/share/icons/hicolor/256x256/apps/system-logo-icon.png`. This is verified distribution branding, not inferred from Huawei's website favicon. |
| TencentOS | Use the cloud figure from TencentOS's own GDM logo, omitting the text. The vendor and distribution share this figure. | [TencentOS official repository package](https://mirrors.tencent.com/tencentos/4/BaseOS/x86_64/os/Packages/system-logos-1.0.7-2.tl4.noarch.rpm), `usr/share/pixmaps/tencentos-gdm-logo.png`; the lockup explicitly reads “TencentOS Server”. |
| Alibaba Cloud Linux | Replace the standalone Alibaba Cloud corporate mark with the conventional Alibaba Linux penguin. This is not claimed to be a separately published official brand master. | SUSE/Uyuni presentation, page 12, embeds the bracket-marked penguin in its supported Alibaba Cloud Linux 2 distribution section. |
| BC-Linux | Replace China Mobile's corporate logo with BC-Linux's blue/yellow penguin, omitting the wordmark. | [BC-Linux's official distribution mirror](https://mirrors.cmecloud.cn/bclinux/oe21.10/OS/x86_64/Packages/bclinux-logos-1.0-9.oe1.bclinux.noarch.rpm), `usr/share/icons/hicolor/256x256/apps/system-logo-icon.png`. The former `bclinux.org` site returned unrelated content during the audit and was not used. |
| NFS / 方德 | Use the standalone red De figure; remove the rest of the company lockup. | The [official server OS manual](https://www.nfschina.com/data/upload/image/20241129/fwq_yhsc.pdf), figure 3-52 (printed page 54), shows it in the “NFSChina Server 4.0” system upgrade tool. The [official De badge source](https://www.nfschina.com/data/upload/image/20210906/1630914044118736.png) is cropped to the red graphic; its white lettering is retained and the NFS-CHINA caption is omitted. |
| iSoft / 普华 | Replace the CETC parent-company wordmark with the standalone S figure assigned to the server operating system. | [Official product catalogue](https://www.i-soft.com.cn/product/currency.html) labels [this icon](https://www.i-soft.com.cn/uploads/images/2022/0526/LsAysk68qNl5rhhIxydktnOaSPRaoghu1TXRKKNt.png) “普华太极服务器操作系统 V6.0”. The `isoft` probe does not distinguish desktop/server versions, so the preview explicitly identifies the server-product artwork. A separate neutral white circular backplate is drawn behind the unmodified source image in the host list, Tabs, and native menu. Status tint affects only the foreground; the source SVG/RGBA and original navy ink are retained. |

## Reproducible extraction

`scripts/os_logo_extract.py` is called by both existing artwork generators.
It reads only the named image inside each RPM; no package is installed or run.
It extracts the two conventional penguins from page 12 of the cited PDF, with
an expected image-size check. Cropping removes text and surrounding page matte;
source figures are neither traced nor generated by AI. Existing icon IDs and
the colour/attention behaviour of hosts, Tabs, and the native menu are unchanged.

The NeoKylin reproduction has limited source sharpness. Its white matte and
wordmark are removed, retaining the red/orange product figure. This limitation
is a raster-source quality issue, not an unresolved product identity.

Selected source SHA-256 values:

| Source | SHA-256 |
| --- | --- |
| Red Hat favicon | `1ad04e9b71110d2dc153ab33bd19eb2ecc9066d18ebd510e41d29781ad2be303` |
| NeoKylin reproduction | `d4af645dbb7f2070f4958946b4a9a104fb80f610c9f4f87909a0065283570dd3` |
| EulerOS logos RPM | `af9424ce2823450f04f08b55daf87d4157090257c1943bd15efbd8ea10645f39` |
| TencentOS logos RPM | `81266b626a960b7860a5cd01ad5b31030aa872085ab5c0209765f3b62da0dbb4` |
| SUSE HEPIX PDF | `f8ca8d8c566a646c921e06dede2fc96b743830e1fecb7f6c26ca0c444fca9f5c` |
| BC-Linux logos RPM | `f59be79ad64ea2d022d20f4051d71546e7ed9a65d9ef2770a1c9e6ccc667fa68` |
| NFS badge PNG | `f7eb305836519c7b975dc04726d0d0cf2ed02ebb0a2aa24a1bd655cc880214f9` |
| iSoft server icon | `7871b133273350801370756d25ad3191c4ef70a4def0bd3e6b276a4ada314595` |

Brand marks retain their respective owners' trademark/copyright terms. Existing
software licenses do not relicense these marks. The extracted EulerOS and
BC-Linux package notices are preserved in `LICENSE-DISTRIBUTION-LOGOS`.

## Dark-background readability pass (2026-11-03)

All 44 currently supported OS/category marks were reviewed on dark window and
selected-row surfaces at the existing 18px host and 14px Tab sizes. Debian,
Alpine, FreeBSD, BC-Linux, NetBSD and Red Flag Linux received narrow display-only
contrast helpers; the other marks and iSoft's previously approved backplate
retain their existing treatment. See the [helper table](README.md).

No source SVG or source RGBA was replaced or recoloured. The reproducible helper
generator checks exact preservation of opaque source RGBA pixels and keeps
exterior padding transparent. Host, Tab and native menu use the same enhanced
normal-state pixels. Connecting/failure states continue to use the original
foreground alpha, so helper contours/negative-space fills do not become part of
the gray/red status glyph. The source/brand findings above remain unchanged.

## Wordmarks replaced with system figures (2026-11-03)

The current openKylin and Ubuntu Kylin brand pages provide wordmarks. For the
14px/18px OS slots, use the independent graphical distribution icon from each
project's own system theme. Both themes provide the same blue/white Kylin
figure; this is explicitly a shared system mark, not a newly claimed unique
community logo. The Loongnix website favicon identifies the community rather
than the OS; replace it with the distribution's own coloured dragon launcher.

| OS | Verified system artwork |
| --- | --- |
| openKylin | `icons/ukui-icon-theme-default/256x256/apps/distributor-logo-kylin.png` in the [official system theme](https://gitee.com/openkylin/openkylin-theme/blob/36f233d1d0cb7c8ca446d34ed3b6687ecfdcc282/icons/ukui-icon-theme-default/256x256/apps/distributor-logo-kylin.png), pinned commit `36f233d1d0cb7c8ca446d34ed3b6687ecfdcc282`. |
| Ubuntu Kylin | `icons/ukui/256x256/places/distributor-logo-kylin.png` in the [official theme repository](https://github.com/UbuntuKylin/ubuntukylin-theme/blob/d6038b6dfaeb1b4761458e0950753a0598d49a1b/icons/ukui/256x256/places/distributor-logo-kylin.png), pinned commit `d6038b6dfaeb1b4761458e0950753a0598d49a1b`. The PNG is byte-identical to openKylin's icon (SHA-256 `e7f2533f83e9498359ad63662d7930eb725d12b24aaec630887c9f07fa2a50f3`). |
| Loongnix | `usr/share/loongnix-theme/Loongnix-Icon/places/scalable/start-here-symbolic.png` (960×960, coloured despite its filename) in the [official `loongnix-theme_1.0.0-1.lnd.3_loongarch64.deb`](https://pkg.loongnix.cn/loongnix/pool/main/l/loongnix-theme/loongnix-theme_1.0.0-1.lnd.3_loongarch64.deb). Its native pink disc and red/orange dragon are retained. |

The generator reads only the named Loongnix image through the Debian archive's
`data.tar.xz`; no package is installed or executed. None of the three figures is
traced, recoloured, or AI-generated. Existing icon IDs and the shared host/Tab/
native-menu presentation remain unchanged. Upstream package copyright notices
are preserved in `LICENSE-DISTRIBUTION-LOGOS`; `LICENSE-UKUI` includes GPLv3.

Loongnix source package SHA-256: `58cb49e403eedd2d092d52fbe51595e498d03de22c310c181630a48f81435ecf`.
Extracted 960px PNG SHA-256: `81e486e3f41936fabf54b5e51c1148e7be0723d08b59a382823b5963cc91ed75`.
