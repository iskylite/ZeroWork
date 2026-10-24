#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${ZEROWORK_SSH_PASSWORD:-}" ] && [ -z "${ZEROWORK_SSH_KEY:-}" ] && [ -z "${ZEROWORK_SSH_AGENT:-}" ]; then echo "set ZEROWORK_SSH_PASSWORD, ZEROWORK_SSH_KEY, or ZEROWORK_SSH_AGENT for the disposable test VM" >&2; exit 2; fi
"$ROOT/scripts/build_ssh_deps.sh"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 \
  -I "$ROOT/vendor/libssh2/include" -I "$ROOT/vendor/libssh2/src" \
  -I "$ROOT/vendor/mbedtls/include" "$ROOT/src/proto/ssh_smoke.c" \
  "$ROOT/vendor/libssh2/src/.libs/libssh2.a" \
  "$ROOT/vendor/mbedtls/library/libmbedcrypto.a" \
  -lz \
  -o /tmp/zerowork-ssh-smoke
/tmp/zerowork-ssh-smoke "${ZEROWORK_SSH_HOST:?set the explicit disposable test host}" "${ZEROWORK_SSH_USER:-root}"
