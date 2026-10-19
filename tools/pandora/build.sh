#!/bin/bash
# Native macOS (arm64) build of Pandora Behaviour Engine+ (GPL-3.0, github.com/Monitor221hz/Pandora-Behaviour-Engine-Plus)
# at a pinned commit plus tools/pandora/macos.patch. Output: $SKYRIM_HOME/tools/pandora (what the mod manager runs).
# Needs the .NET 10 SDK (brew install dotnet). Developer tool: end users get the prebuilt folder.
#   tools/pandora/build.sh [--src <checkout>]
. "$(dirname "$0")/../../scripts/_env.sh"   # before strict mode: _env.sh tolerates missing optional files
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # this script (hashed into the build id)
REPO=https://github.com/Monitor221hz/Pandora-Behaviour-Engine-Plus
COMMIT=1f26bbc2eb3ab5222916495af164b756bb0e5775   # v5.0.0-beta + 0 (2026-10)
PATCH="$SKYRIMMT_ROOT/tools/pandora/macos.patch"
SRC="$SKYRIM_HOME/cache/pandora-src"; [ "${1:-}" = --src ] && SRC=$2
OUT="${SKYRIMMT_TOOL_OUT:-$SKYRIM_HOME/tools/pandora}"   # release builds: a staging folder

command -v dotnet >/dev/null || { echo "dotnet SDK missing (brew install dotnet)"; exit 1; }
if [ ! -d "$SRC/.git" ]; then
  git clone -q --recurse-submodules "$REPO" "$SRC"
fi
cd "$SRC"
if ! git diff --quiet && ! cmp -s <(git diff) "$PATCH"; then
  echo "$SRC has local changes that differ from macos.patch — update the patch (git diff > macos.patch) or clean it"; exit 1
fi
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  git checkout -q -- . && { git cat-file -e "$COMMIT" 2>/dev/null || git fetch -q origin; } && git checkout -q "$COMMIT"
  git submodule update -q --init --recursive
fi
git diff --quiet && git apply "$PATCH"
tmp="$OUT.new"; rm -rf "$tmp"
dotnet publish Pandora.Engine/Pandora.Engine.csproj -c Release -r osx-arm64 --self-contained true -p:PathMap="$SRC=/src" -p:DebugType=none -o "$tmp" -v q -nologo |
  grep -E ' error ' || true
[ -x "$tmp/Pandora Behaviour Engine+" ] || { echo "build failed"; exit 1; }
rm -f "$tmp"/*.pdb "$tmp/Settings.json"
printf '%s %s\n' "$COMMIT" "$(cat "$PATCH" "$SELF" | shasum -a 256 | cut -c1-16)" > "$tmp/.skyrimmt-pandora"   # build id: source, patch, build settings
rm -rf "$OUT"; mv "$tmp" "$OUT"
echo "Pandora built: $OUT"
