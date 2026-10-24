# libdecor ABI header

`libdecor.h` was retrieved from upstream on 2026-10-10:
https://gitlab.freedesktop.org/libdecor/libdecor/-/raw/master/src/libdecor.h

SHA-256: `fee55d0ab556e4cebbe551821a706e0c30f9e30cd4d72d04d36cdf9f9aa035e2`.

The upstream MIT license and copyright notices are preserved in the header.
Only declarations are vendored; the implementation and plugins come from the
Linux distribution. The runtime ABI is verified with Fedora 44 libdecor 0.2.5.
Zenit loads `libdecor-0.so.0` dynamically and requires a working decoration
plugin; failure to initialize decorations is reported instead of silently
creating a window without controls.
