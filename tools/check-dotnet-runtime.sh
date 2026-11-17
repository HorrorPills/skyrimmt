#!/bin/bash
# Check a self-contained .NET publish folder before it ships: its .NET runtime must run on the oldest macOS SkyrimMT
# supports (15). Homebrew's .NET is built from source against the build Mac's own macOS SDK — built on macOS 27 the
# runtime calls pipe2(), which macOS 15 doesn't have, and Pandora crashed at start on every older Mac (issue #28).
# Microsoft's runtime (dotnet-install.sh) is built against an old SDK and Developer ID-signed from .NET 9 on.
#   tools/check-dotnet-runtime.sh <publish folder>      exit 0 = OK
set -uo pipefail
dir=${1:?usage: check-dotnet-runtime.sh <publish folder>}
SUPPORTED=15   # oldest macOS SkyrimMT supports (README)
bad=0
for f in "$dir"/libcoreclr.dylib "$dir"/libclrjit.dylib "$dir"/libSystem.Native.dylib "$dir"/libhostfxr.dylib "$dir"/libhostpolicy.dylib; do
  [ -f "$f" ] || { echo "missing: ${f##*/}"; bad=1; continue; }
  n=${f##*/}
  ms=0; codesign -dv "$f" 2>&1 | grep -q '^TeamIdentifier=UBF8T346G9$' && ms=1   # Microsoft Corporation
  sdk=$(otool -l "$f" | awk '/^ *sdk /{print $2; exit}')
  minos=$(otool -l "$f" | awk '/^ *minos /{print $2; exit}')
  if [ "${minos%%.*}" -gt "$SUPPORTED" ]; then echo "$n needs macOS $minos"; bad=1; fi
  if [ "$ms" = 0 ] && [ "${sdk%%.*}" -gt "$SUPPORTED" ]; then
    echo "$n: built against the macOS $sdk SDK and not Microsoft's build — may call functions macOS $SUPPORTED lacks"; bad=1
  fi
  if dyld_info -imports "$f" 2>/dev/null | grep -q '_pipe2'; then echo "$n imports pipe2() (not in macOS $SUPPORTED)"; bad=1; fi
done
[ "$bad" = 0 ] && exit 0
echo "→ publish with Microsoft's .NET SDK (curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0), not Homebrew's"
exit 1
