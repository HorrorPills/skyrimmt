#!/bin/bash
# Build the SkyrimMT Mac Fixes SKSE plugin (x86_64 mingw: brew install mingw-w64) → build/skse/SkyrimMT_MacFixes.dll
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/build/skse"; mkdir -p "$OUT"
x86_64-w64-mingw32-gcc -O2 -shared -s -Wall -o "$OUT/SkyrimMT_MacFixes.dll" "$ROOT/tools/skse-macfixes/macfixes.c" -luser32 -Wl,--kill-at
echo "$OUT/SkyrimMT_MacFixes.dll"
