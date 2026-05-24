#!/usr/bin/env bash
# Golden-file harness for the unrawk-installer headless mode.
#
# For each seed under tests/seeds/, run the installer headless and diff
# the structured-log output against the committed golden under
# tests/golden/. Exits non-zero on any mismatch.
#
# Update goldens after an intentional output-format change with:
#   tests/run.sh --update
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$PROJECT_DIR/unrawk_installer"
SEEDS_DIR="$PROJECT_DIR/tests/seeds"
GOLDEN_DIR="$PROJECT_DIR/tests/golden"

UPDATE=0
if [ "${1:-}" = "--update" ]; then UPDATE=1; fi

if [ ! -x "$BIN" ]; then
    echo "error: binary not found at $BIN" >&2
    echo "       build it first: nim c -d:wayland -d:release -o:./unrawk_installer src/unrawk_installer.nim" >&2
    exit 2
fi

mkdir -p "$GOLDEN_DIR"
shopt -s nullglob
pass=0; fail=0

for seed in "$SEEDS_DIR"/*.seed; do
    name=$(basename "$seed" .seed)
    golden="$GOLDEN_DIR/$name.txt"
    got=$("$BIN" --headless --seed="$seed")
    if [ $UPDATE -eq 1 ] || [ ! -f "$golden" ]; then
        printf '%s\n' "$got" > "$golden"
        echo "wrote  $name.txt"
        continue
    fi
    if printf '%s\n' "$got" | diff -u "$golden" - > /dev/null; then
        echo "pass   $name"
        pass=$((pass+1))
    else
        echo "FAIL   $name"
        printf '%s\n' "$got" | diff -u "$golden" - || true
        fail=$((fail+1))
    fi
done

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
