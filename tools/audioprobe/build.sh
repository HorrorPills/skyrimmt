#!/bin/bash
# Build audioprobe.exe (x86_64 mingw: brew install mingw-w64) → build/audioprobe/audioprobe.exe
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/build/audioprobe"; mkdir -p "$OUT"
x86_64-w64-mingw32-gcc -O2 -s -Wall -o "$OUT/audioprobe.exe" "$ROOT/tools/audioprobe/audioprobe.c" -lole32 -lversion
echo "$OUT/audioprobe.exe"
