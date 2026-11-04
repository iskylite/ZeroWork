# Saved-host colour icons

Linux, Ubuntu, Debian, Fedora , Arch Linux and Rocky Linux: Devicon original SVGs, MIT license
(included as LICENSE). Source: https://github.com/devicons/devicon/tree/master/icons

Saved hosts always retain source colours. iSoft’s dark mark has a separately
painted white circular backplate for contrast; the original source artwork is
unchanged. Tabs and native menu items share this backplate, while connection
state colours apply only to the foreground. Tabs use the same OS artwork in
source colours normally, a solid red alpha mask for connection failures, and
a solid gray alpha mask while connecting. Normal exit/closed states retain
the original artwork. Protocol glyphs without multicolour artwork keep their
normal theme ink outside the two connection warning states.
`src/ui/host_os_assets.zig` assigns independent IDs to these resources.
Before the renderer is ready, existing native geometry supplies a fallback;
once ready, saved-host and OS Tab nodes use uploaded textures.

Six marks also have selective `*-contrast.rgba` display derivatives. They add
helper ink behind the unchanged original artwork rather than recolouring it or
giving every logo a white tile:

| OS | Display helper |
| --- | --- |
| Debian | Fine, muted rose contour around the dark thin swirl |
| Alpine | Ice-blue fill in the mountain's enclosed transparent negative space |
| FreeBSD | Fine, warm-gray contour to keep the dark red silhouette distinct |
| BC-Linux | Cream fill in the penguin's enclosed transparent negative space |
| NetBSD | Local ivory contour behind the gray letters/pole; orange flag unchanged |
| Red Flag Linux | Local ivory contour behind the black Linux lettering only |

`scripts/generate_os_contrast_assets.py` regenerates these derivatives from the
original 72px RGBA files and checks that every opaque source pixel retains its
exact RGBA. Run it after regenerating any of the six source assets. Original
SVGs and RGBA files stay intact. Normal host/Tab/native-menu artwork shares
`host_os_assets.display_pixels`; gray/red warning masks still use original
`host_os_assets.pixels`, without the added helper. iSoft's separate white
backplate remains neutral in every state. Other OS artwork is unchanged.

Alpine Linux and FreeBSD SVGs come from Simple Icons (CC0):
https://github.com/simple-icons/simple-icons . Their brand fills are #0D597F and
#AB2B28. Windows 11 is from Devicon (MIT).

`.rgba` files are 72×72 straight RGBA browser renders on transparent backgrounds
(4× the logical 18px host slot). They preserve multicolour fills and gradients;
the framework's icon geometry deliberately supports only theme tint. Each window
uploads and owns its host artwork textures, releasing them on window cleanup.
To regenerate, render each SVG at 72×72 with transparent background in Chromium,
then export `PIL.Image.open(png).convert('RGBA').tobytes()` to the matching file.

Rocky Linux: `rockylinux/rockylinux-original.svg` from the Devicon source above.
The matching tintable tab geometry is `src/ui/rocky_os_asset.zig` (ID 54003).
Regenerate it with zenit's `gen_svg_assets` tool using an input directory that
contains only `rocky.svg`, embed prefix `assets/os/`, and base icon ID 54003;
this keeps the existing tab asset IDs stable.

## Domestic operating systems

Domestic distribution artwork is shared by saved hosts and live tabs, with
the state colour rules above. The existing 14px tab and 18px host slots stay
unchanged. Unread background tabs animate their icon independently of colour;
the same artwork, colour mode, and activity state feed the native menu-bar list.
The native menu uses the shared RGBA pixels to preserve original brand colours.
Existing icon IDs remain stable (new IDs: 54109–54128).

`scripts/generate_domestic_os_assets.py` records the exact upstream asset URLs
and regenerates the SVG resources and 72×72 straight RGBA derivatives using
Pillow and resvg-py (plus `tar`/Poppler for audited package/PDF sources). ICO resources use their largest supplied image; transparent
padding is removed before fitting the artwork to the existing icon slot. Embedded PNG
SVGs preserve upstream raster artwork; they are not invented vector logos.

| OS | Brand asset source |
| --- | --- |
| Kylin / 银河麒麟 | [UKUI's Kylin start icon](https://github.com/ukui/ukui-themes/blob/master/icons/ukui-classical/scalable/places/start-here.svg), GPL-3.0; see LICENSE-UKUI |
| NeoKylin / 中标麒麟 | Red qilin distribution figure, cross-checked against the official V7 installer; see [audit](OS_LOGO_AUDIT.md) |
| openKylin | Blue/white Kylin distribution figure from the [official system theme](https://gitee.com/openkylin/openkylin-theme/blob/36f233d1d0cb7c8ca446d34ed3b6687ecfdcc282/icons/ukui-icon-theme-default/256x256/apps/distributor-logo-kylin.png); shared with Ubuntu Kylin, not a unique community brand master |
| Ubuntu Kylin / 优麒麟 | Same standalone distribution figure in the [official Ubuntu Kylin theme](https://github.com/UbuntuKylin/ubuntukylin-theme/blob/d6038b6dfaeb1b4761458e0950753a0598d49a1b/icons/ukui/256x256/places/distributor-logo-kylin.png); source colours retained |
| UnionTech UOS / 统信 | [UnionTech](https://www.chinauos.com/), official U mark |
| deepin / 深度 | [Simple Icons](https://github.com/simple-icons/simple-icons/blob/develop/icons/deepin.svg), CC0; #007CFF |
| openEuler | [openEuler](https://www.openeuler.org/en/other/brand/), official favicon |
| EulerOS | Flower from the official `euleros-logos` distribution package; [audit](OS_LOGO_AUDIT.md) |
| Anolis / 龙蜥 | [OpenAnolis](https://openanolis.cn/), official site icon |
| OpenCloudOS | [OpenCloudOS](https://www.opencloudos.org/), official site icon |
| TencentOS | Graphical component of the distribution’s own `tencentos-gdm-logo.png`; [audit](OS_LOGO_AUDIT.md) |
| Alibaba Cloud Linux | Conventional Alibaba Linux penguin used in SUSE/Uyuni distribution materials; [audit](OS_LOGO_AUDIT.md) |
| Loongnix | Dragon launcher mark from the [official `loongnix-theme` package](https://pkg.loongnix.cn/loongnix/pool/main/l/loongnix-theme/loongnix-theme_1.0.0-1.lnd.3_loongarch64.deb), `Loongnix-Icon/places/scalable/start-here-symbolic.png`; native pink badge and red/orange colours retained |
| AOSC / 安同 | [AOSC](https://aosc.io/), official site icon |
| BC-Linux | Blue/yellow penguin from the official `bclinux-logos` package; [audit](OS_LOGO_AUDIT.md) |
| KylinSec / 麒麟信安 | [KylinSec](https://www.kylinsec.com.cn/), official site icon |
| NFS / 中科方德 | Standalone red De mark verified in the official OS manual; [audit](OS_LOGO_AUDIT.md) |
| Linx / 凝思 | [Linx](https://www.linx-info.com/), official site icon |
| iSoft / 普华 | Standalone S figure assigned to the server OS in the official product catalogue; [audit](OS_LOGO_AUDIT.md) |
| Red Flag / 红旗 | [Red Flag](https://www.chinaredflag.cn/), official Linux wordmark |

Brand marks remain the property of their respective owners and are used only
for OS identification. Website marks retain their upstream copyright/trademark
terms; the software's license does not relicense those marks.

Identification uses the distribution's own `ID`, including case variants and
known product aliases, rather than `ID_LIKE` or arbitrary terminal output. An
Ubuntu Kylin installation that reports only `ID=ubuntu` remains Ubuntu; this
read-only probe does not guess a variant that its metadata did not provide.

## Additional international operating systems

This selection covers enterprise/cloud servers, developer and security Linux
distributions, and the BSD family. IDs 54129–54142 append to the existing range;
saved-host, Tab, and menu-bar artwork use the same original/state-colour rules.
Regenerate with `scripts/generate_international_os_assets.py` (Pillow,
resvg-py, and Poppler for PDF extraction). Sources distinguish first-party
product artwork from conventional distribution illustrations:

| OS | Identification | Artwork source |
| --- | --- | --- |
| Red Hat Enterprise Linux | `ID=rhel` | Familiar red-hat mark from the [official Red Hat favicon](https://www.redhat.com/favicon.ico); [audit](OS_LOGO_AUDIT.md) |
| CentOS / CentOS Stream | `ID=centos` | [CentOS](https://www.centos.org/), official symbol favicon |
| AlmaLinux | `ID=almalinux` | [AlmaLinux brand assets](https://almalinux.org/branding/), colour icon |
| Oracle Linux | `ID=ol` | [Oracle Linux yum server](https://yum.oracle.com/), official penguin favicon |
| SUSE Linux Enterprise | `ID=sles` / `sled` | [SUSE](https://www.suse.com/), official chameleon favicon |
| openSUSE | `ID=opensuse`, `opensuse-leap`, `opensuse-tumbleweed`, `opensuse-microos`, `opensuse-slowroll` | [openSUSE static assets](https://static.opensuse.org/), project gecko favicon |
| Amazon Linux | `ID=amzn` | Conventional Amazon Linux penguin used in SUSE/Uyuni distribution materials; [audit](OS_LOGO_AUDIT.md) |
| NixOS | `ID=nixos` | [NixOS branding](https://nixos.org/branding/), official snowflake favicon |
| Gentoo | `ID=gentoo` | [Gentoo artwork](https://www.gentoo.org/inside-gentoo/artwork/), Gentoo G |
| Kali Linux | `ID=kali` | [Official Kali press pack](https://gitlab.com/kalilinux/documentation/press-pack), blue logomark/wordmark |
| Linux Mint | `ID=linuxmint` | [Linux Mint](https://www.linuxmint.com/), official LM favicon |
| Manjaro | `ID=manjaro` | [Manjaro](https://manjaro.org/), official standalone mark |
| OpenBSD | `uname -s`: `OpenBSD` | [OpenBSD](https://www.openbsd.org/), official Puffy favicon |
| NetBSD | `uname -s`: `NetBSD` | [NetBSD logos](https://www.netbsd.org/gallery/logos.html), transparent flag logo |

CentOS versions share the same distribution identity; openSUSE variants share
the umbrella project logo. Amazon Linux and Alibaba Cloud Linux use conventional distribution penguins,
with provenance and classification recorded in [the logo audit](OS_LOGO_AUDIT.md). The read-only probe follows the
`/etc/os-release` → `/usr/lib/os-release` fallback. BSD hosts without either
file retain the exact kernel identity and do not run a Linux-only dependency.
