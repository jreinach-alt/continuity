#!/bin/sh
# Cross-compile a static git binary for aarch64 (TrimUI Brick / NextUI)
#
# Dependencies: gcc-aarch64-linux-gnu, make, autoconf, gettext, perl
#
# Produces: build/aarch64/bin/git (static, ~5-10MB)
#
# Builds from source: zlib, openssl, curl, git
# All linked statically — no shared library dependencies on device.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build/aarch64"
SRC_DIR="$BUILD_ROOT/src"
PREFIX="$BUILD_ROOT/prefix"

CROSS=aarch64-linux-gnu
CC="${CROSS}-gcc"
AR="${CROSS}-ar"
RANLIB="${CROSS}-ranlib"
STRIP="${CROSS}-strip"

# Versions
# openssl tracks the 3.0 LTS line — its pristine upstream tarball is
# mirrored by Ubuntu, reachable from restricted build hosts where
# github.com release downloads and openssl.org are not.
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.0.13"
CURL_VERSION="8.11.1"
GIT_VERSION="2.47.1"

# URLs — canonical non-GitHub mirrors: kernel.org ships git's proper
# dist tarballs (Makefile ready, no autoconf step); curl.se and
# zlib.net are the projects' own hosts.
ZLIB_URL="https://www.zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_URL="http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/openssl_${OPENSSL_VERSION}.orig.tar.gz"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
GIT_URL="https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.gz"

NPROC=$(nproc 2>/dev/null || echo 2)

log() {
    printf "\n=== %s ===\n\n" "$1"
}

download() {
    url="$1"
    dest="$2"
    if [ -f "$dest" ]; then
        printf "  Already downloaded: %s\n" "$(basename "$dest")"
        return 0
    fi
    printf "  Downloading: %s\n" "$(basename "$dest")"
    curl -fSL --retry 3 -o "$dest" "$url"
}

mkdir -p "$SRC_DIR" "$PREFIX/lib" "$PREFIX/include"

# ── zlib ─────────────────────────────────────────────────────────────
log "Building zlib ${ZLIB_VERSION}"

download "$ZLIB_URL" "$SRC_DIR/zlib-${ZLIB_VERSION}.tar.gz"

if [ ! -f "$PREFIX/lib/libz.a" ]; then
    cd "$SRC_DIR"
    rm -rf "zlib-${ZLIB_VERSION}"
    tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
    cd "zlib-${ZLIB_VERSION}"

    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
        ./configure --static --prefix="$PREFIX"
    make -j"$NPROC"
    make install
    printf "  zlib installed to %s\n" "$PREFIX"
else
    printf "  zlib already built\n"
fi

# ── OpenSSL ──────────────────────────────────────────────────────────
log "Building OpenSSL ${OPENSSL_VERSION}"

download "$OPENSSL_URL" "$SRC_DIR/openssl-${OPENSSL_VERSION}.tar.gz"

if [ ! -f "$PREFIX/lib/libssl.a" ]; then
    cd "$SRC_DIR"
    rm -rf "openssl-${OPENSSL_VERSION}"
    tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
    cd "openssl-${OPENSSL_VERSION}"

    # note: no-docs is a 3.2+ option; 3.0's Configure rejects it and
    # `make install_sw` skips docs regardless
    ./Configure linux-aarch64 \
        --cross-compile-prefix="${CROSS}-" \
        --prefix="$PREFIX" \
        no-shared \
        no-tests \
        no-engine \
        no-dso \
        -static
    make -j"$NPROC"
    make install_sw
    printf "  OpenSSL installed to %s\n" "$PREFIX"
else
    printf "  OpenSSL already built\n"
fi

# ── curl ─────────────────────────────────────────────────────────────
log "Building curl ${CURL_VERSION}"

download "$CURL_URL" "$SRC_DIR/curl-${CURL_VERSION}.tar.gz"

if [ ! -f "$PREFIX/lib/libcurl.a" ]; then
    cd "$SRC_DIR"
    rm -rf "curl-${CURL_VERSION}"
    tar xzf "curl-${CURL_VERSION}.tar.gz"
    cd "curl-${CURL_VERSION}"

    ./configure \
        --host="${CROSS}" \
        --prefix="$PREFIX" \
        --with-openssl="$PREFIX" \
        --with-zlib="$PREFIX" \
        --disable-shared \
        --enable-static \
        --disable-ldap \
        --disable-ldaps \
        --disable-rtsp \
        --disable-dict \
        --disable-telnet \
        --disable-tftp \
        --disable-pop3 \
        --disable-imap \
        --disable-smb \
        --disable-smtp \
        --disable-gopher \
        --disable-mqtt \
        --disable-manual \
        --without-libpsl \
        --without-brotli \
        --without-zstd \
        --without-libidn2 \
        --without-libssh2 \
        --without-nghttp2 \
        CFLAGS="-I$PREFIX/include" \
        LDFLAGS="-L$PREFIX/lib -static" \
        LIBS="-lssl -lcrypto -lz -lpthread -ldl"
    make -j"$NPROC"
    make install
    printf "  curl installed to %s\n" "$PREFIX"
else
    printf "  curl already built\n"
fi

# ── git ──────────────────────────────────────────────────────────────
log "Building git ${GIT_VERSION}"

download "$GIT_URL" "$SRC_DIR/git-${GIT_VERSION}.tar.gz"

cd "$SRC_DIR"
rm -rf "git-${GIT_VERSION}"
tar xzf "git-${GIT_VERSION}.tar.gz"
# GitHub archive uses "git-v${VERSION}" as the directory name
if [ -d "git-${GIT_VERSION}" ]; then
    cd "git-${GIT_VERSION}"
else
    cd "git-${GIT_VERSION}" 2>/dev/null || cd git-*"${GIT_VERSION}"*
fi

# For GitHub archive sources, we need to generate the configure script
if [ ! -f Makefile ] && [ -f GIT-VERSION-GEN ]; then
    make configure
fi

# Git's build needs some host tools (msgfmt, etc.) — skip if missing
make -j"$NPROC" \
    CC="$CC" \
    AR="$AR" \
    STRIP="$STRIP" \
    CFLAGS="-I$PREFIX/include -static" \
    LDFLAGS="-L$PREFIX/lib -static" \
    CURL_LIBCURL="-lcurl -lssl -lcrypto -lz -lpthread -ldl" \
    NO_TCLTK=1 \
    NO_GETTEXT=1 \
    NO_PERL=1 \
    NO_PYTHON=1 \
    NO_EXPAT=1 \
    NO_REGEX=1 \
    NO_NSEC=1 \
    NO_INSTALL_HARDLINKS=1 \
    prefix="$PREFIX" \
    gitexecdir="$PREFIX/libexec/git-core"

# Install just the binary and essential helpers
make install \
    CC="$CC" \
    AR="$AR" \
    STRIP="$STRIP" \
    CFLAGS="-I$PREFIX/include -static" \
    LDFLAGS="-L$PREFIX/lib -static" \
    CURL_LIBCURL="-lcurl -lssl -lcrypto -lz -lpthread -ldl" \
    NO_TCLTK=1 \
    NO_GETTEXT=1 \
    NO_PERL=1 \
    NO_PYTHON=1 \
    NO_EXPAT=1 \
    NO_REGEX=1 \
    NO_NSEC=1 \
    NO_INSTALL_HARDLINKS=1 \
    prefix="$PREFIX" \
    gitexecdir="$PREFIX/libexec/git-core"

"$STRIP" "$PREFIX/bin/git" 2>/dev/null || true
"$STRIP" "$PREFIX/libexec/git-core/git-remote-https" 2>/dev/null || true
"$STRIP" "$PREFIX/libexec/git-core/git-remote-http" 2>/dev/null || true

# HTTPS transport lives in a SEPARATE helper binary that git exec's at
# runtime. A build without it produces a git that clones file:// but
# fails https:// with "unable to find remote helper for 'https'" —
# exactly the on-device enrollment failure this guard prevents.
if [ ! -x "$PREFIX/libexec/git-core/git-remote-https" ]; then
    printf 'ERROR: git-remote-https was not built — HTTPS will not work on device.\n' >&2
    printf 'Check that curl was detected by the git build.\n' >&2
    exit 1
fi

# ── Output ───────────────────────────────────────────────────────────
log "Build complete"

OUTPUT_DIR="$PROJECT_ROOT/build/aarch64/bin"
mkdir -p "$OUTPUT_DIR"

GIT_SIZE=$(ls -l "$PREFIX/bin/git" | awk '{print $5}')
GIT_SIZE_MB=$((GIT_SIZE / 1024 / 1024))

printf "  git binary: %s (%d MB)\n" "$PREFIX/bin/git" "$GIT_SIZE_MB"
printf "  Verify: file %s\n" "$PREFIX/bin/git"
file "$PREFIX/bin/git"

printf "\n  Copy to PAK: cp %s/bin/git <Continuity.pak/bin/git>\n" "$PREFIX"
