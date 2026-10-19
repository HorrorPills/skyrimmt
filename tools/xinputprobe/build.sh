#!/bin/bash
# Build xinputprobe.exe (x86_64 mingw: brew install mingw-w64) → build/xinputprobe/xinputprobe.exe
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; OUT="$ROOT/build/xinputprobe"; mkdir -p "$OUT"
x86_64-w64-mingw32-gcc -O2 -s -Wall -o "$OUT/xinputprobe.exe" "$ROOT/tools/xinputprobe/xinputprobe.c"
echo "$OUT/xinputprobe.exe"
