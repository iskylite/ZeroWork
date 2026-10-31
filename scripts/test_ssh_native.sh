#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
python3 scripts/verify_ssh_deps.py
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
xcrun clang -std=c11 -g -fsanitize=address,undefined \
  -Ivendor/libssh2/src -Ivendor/libssh2/include -Ivendor/mbedtls/include -DHAVE_CONFIG_H \
  src/proto/ssh/ssh_security_test.c vendor/libssh2/src/.libs/libssh2.a \
  vendor/mbedtls/library/libmbedcrypto.a -lz -o "$OUT/security"
"$OUT/security"
xcrun clang -std=c11 -g -fsanitize=address,undefined \
  -Isrc/proto/ssh -Ivendor/libssh2/include src/proto/ssh/ssh_socket_cancel_test.c \
  vendor/libssh2/src/.libs/libssh2.a vendor/mbedtls/library/libmbedcrypto.a -lz -o "$OUT/sockets"
"$OUT/sockets"
xcrun clang -std=c11 -g -fsanitize=address,undefined \
  -Isrc/proto/ssh -Ivendor/libssh2/include src/proto/ssh/ssh_handshake_diagnostic_test.c \
  vendor/libssh2/src/.libs/libssh2.a vendor/mbedtls/library/libmbedcrypto.a -lz -o "$OUT/handshake-diagnostic"
"$OUT/handshake-diagnostic"
