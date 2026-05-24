#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"
    local strip="${4:-1}"
    local filter="${5:-}"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest" --wildcards "$filter"
    else
        curl -fsSL "$url" | tar xz --strip-components="$strip" -C "$dest"
    fi
    echo "  done."
}

echo "==> wayluigi"
if [ -d "$VENDOR/wayluigi" ] && [ -n "$(ls -A "$VENDOR/wayluigi" 2>/dev/null)" ]; then
    echo "  already present: wayluigi"
else
    echo "  cloning wayluigi..."
    git clone --depth=1 "https://github.com/ItsNotPaths/wayluigi.git" "$VENDOR/wayluigi"
    echo "  done."
fi

echo "==> rawk-luigi"
if [ -d "$VENDOR/rawk-luigi" ] && [ -n "$(ls -A "$VENDOR/rawk-luigi" 2>/dev/null)" ]; then
    echo "  already present: rawk-luigi"
else
    echo "  cloning rawk-luigi..."
    git clone --depth=1 "https://github.com/ItsNotPaths/rawk-luigi.git" "$VENDOR/rawk-luigi"
    echo "  done."
fi

echo "==> freetype headers (for luigi.h's freetype glyph path)"
FT_HEADERS="$VENDOR/wayluigi/freetype"
if [ -d "$FT_HEADERS" ] && [ -f "$FT_HEADERS/ft2build.h" ]; then
    echo "  already present: freetype headers"
else
    echo "  cloning freetype..."
    TMP=$(mktemp -d)
    git clone --depth=1 -q "https://gitlab.freedesktop.org/freetype/freetype.git" "$TMP/freetype"
    mkdir -p "$FT_HEADERS"
    cp -r "$TMP/freetype/include/." "$FT_HEADERS/"
    rm -rf "$TMP"
    echo "  done."
fi

echo ""
echo "All deps ready."
