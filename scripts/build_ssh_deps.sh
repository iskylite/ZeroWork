#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MBED="$ROOT/vendor/mbedtls"
SSH="$ROOT/vendor/libssh2"
JOBS=4
CC=${CC:-"xcrun clang -arch arm64 -mmacosx-version-min=14.0"}
AR=${AR:-"xcrun ar"}
RANLIB=${RANLIB:-"xcrun ranlib"}

command -v xcrun >/dev/null 2>&1 || { echo "build_ssh_deps: xcrun is required" >&2; exit 1; }
test -x "$SSH/configure" || { echo "build_ssh_deps: missing $SSH/configure" >&2; exit 1; }

# Always rebuild both archives from vendored sources. In particular, do not let a
# stale configure result retain a host compiler or a different crypto backend.
make -C "$MBED/library" clean >/dev/null
make -C "$MBED/library" libmbedcrypto.a CC="$CC" AR="$AR" -j"$JOBS"
(
  cd "$SSH"
  if test -f Makefile; then make clean >/dev/null; fi
  CPPFLAGS="-I$MBED/include" LDFLAGS="-L$MBED/library" LIBS="-lmbedcrypto" \
    ./configure --disable-shared --enable-static --disable-examples-build \
      --with-libz --with-crypto=mbedtls CC="$CC" AR="$AR" RANLIB="$RANLIB"
  make -j"$JOBS"
)

test -s "$MBED/library/libmbedcrypto.a"
test -s "$SSH/src/.libs/libssh2.a"
