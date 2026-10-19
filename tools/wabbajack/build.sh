#!/bin/bash
# Native macOS (arm64) build of the Wabbajack installer engine: jackify-engine (GPL-3.0 fork of Wabbajack,
# github.com/Omni-guides/dev-jackify-engine) at a pinned commit plus tools/wabbajack/macos.patch (SkyrimMT Wine instead
# of Proton, game folder / data folder overrides, Microsoft.Data.Sqlite for osx-arm64, Nexus only when needed).
# Output: $SKYRIM_HOME/tools/wabbajack (self-contained .NET). Needs the .NET SDK 8+ (brew install dotnet).
#   tools/wabbajack/build.sh [--src <checkout>]
. "$(dirname "$0")/../../scripts/_env.sh"   # before strict mode: _env.sh tolerates missing optional files
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # this script (hashed into the build id)
REPO=https://github.com/Omni-guides/dev-jackify-engine
COMMIT=9bba7928a1eff9cb7b0c8433e34e970d5e5abf73   # v0.5.10 (2026-09-21)
PATCH="$SKYRIMMT_ROOT/tools/wabbajack/macos.patch"
SRC="$SKYRIM_HOME/cache/wabbajack-src"; [ "${1:-}" = --src ] && SRC=$2
OUT="${SKYRIMMT_TOOL_OUT:-$SKYRIM_HOME/tools/wabbajack}"   # release builds: a staging folder

command -v dotnet >/dev/null || { echo "dotnet SDK missing (brew install dotnet)"; exit 1; }
[ -d "$SRC/.git" ] || git clone -q "$REPO" "$SRC"
cd "$SRC"
if ! git diff --quiet && ! cmp -s <(git diff) "$PATCH"; then
  echo "$SRC has local changes that differ from macos.patch — update the patch (git diff > macos.patch) or clean it"; exit 1
fi
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  git checkout -q -- . && { git cat-file -e "$COMMIT" 2>/dev/null || git fetch -q origin; } && git checkout -q "$COMMIT"
fi
git diff --quiet && git apply "$PATCH"
tmp="$OUT.new"; rm -rf "$tmp"
nice -n 10 dotnet publish jackify-engine/jackify-engine.csproj -c Release -r osx-arm64 --self-contained true -p:PathMap="$SRC=/src" -p:DebugType=none -o "$tmp" -v q -nologo |
  grep -E 'error CS|error NU' || true
[ -x "$tmp/jackify-engine" ] || { echo "build failed"; exit 1; }
chmod +x "$tmp"/Extractors/*/7zz 2>/dev/null || true   # git/publish drop the executable bit
rm -f "$tmp"/*.pdb
printf '%s %s\n' "$COMMIT" "$(cat "$PATCH" "$SELF" | shasum -a 256 | cut -c1-16)" > "$tmp/.skyrimmt-wabbajack"
rm -rf "$OUT"; mv "$tmp" "$OUT"
echo "Wabbajack engine built: $OUT"
