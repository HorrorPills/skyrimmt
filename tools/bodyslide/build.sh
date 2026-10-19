#!/bin/bash
# Native macOS (arm64) build of BodySlide and Outfit Studio (GPL-3.0, github.com/ousnius/BodySlide-and-Outfit-Studio)
# at a pinned tag plus tools/bodyslide/macos.patch. Output: $SKYRIM_HOME/tools/bodyslide (BodySlide, OutfitStudio,
# res/, lang/, bundled wxWidgets + GLEW dylibs) — what the mod manager runs.
# Needs: brew install cmake ninja wxwidgets glew directx-headers dylibbundler. Developer tool: end users get the folder.
#   tools/bodyslide/build.sh [--src <checkout>]
. "$(dirname "$0")/../../scripts/_env.sh"   # before strict mode: _env.sh tolerates missing optional files
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # this script (hashed into the build id)
REPO=https://github.com/ousnius/BodySlide-and-Outfit-Studio
TAG=v6.0.0                                   # same version as the Nexus release (mod 201), 2026-10-13
PATCH="$SKYRIMMT_ROOT/tools/bodyslide/macos.patch"
SRC="$SKYRIM_HOME/cache/bodyslide-src"; [ "${1:-}" = --src ] && SRC=$2
BUILD="$SKYRIM_HOME/cache/bodyslide-build"
OUT="${SKYRIMMT_TOOL_OUT:-$SKYRIM_HOME/tools/bodyslide}"   # release builds: a staging folder

for t in cmake ninja dylibbundler; do command -v $t >/dev/null || { echo "$t missing (brew install $t)"; exit 1; }; done
[ -d "$(brew --prefix)/include/directx" ] || { echo "directx-headers missing (brew install directx-headers)"; exit 1; }
[ -d "$SRC/.git" ] || git clone -q --recurse-submodules "$REPO" "$SRC"
cd "$SRC"
if ! git diff --quiet && ! cmp -s <(git diff) "$PATCH"; then
  echo "$SRC has local changes that differ from macos.patch — update the patch (git diff > macos.patch) or clean it"; exit 1
fi
want=$(git rev-parse -q --verify "$TAG^{commit}" || { git fetch -q --tags origin; git rev-parse "$TAG^{commit}"; })
if [ "$(git rev-parse HEAD)" != "$want" ]; then
  git checkout -q -- . && git checkout -q "$want" && git submodule update -q --init --recursive
fi
git diff --quiet && git apply "$PATCH"
# BC4/BC5/BC7 texture decoders for the macOS preview (bc7enc, MIT / public domain; used by the patched ResourceLoader.cpp)
mkdir -p "$SRC/src/bc7enc" && cp "$SKYRIMMT_ROOT/tools/bodyslide/third_party/bc7enc/"* "$SRC/src/bc7enc/"

# -ffp-contract=off: no fused multiply-add, so float results match the Windows (MSVC x64) build
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBSOS_ENABLE_FBXSDK=OFF \
  -DCMAKE_CXX_FLAGS="-isystem $(brew --prefix)/include -ffp-contract=off -ffile-prefix-map=$SRC=/src -ffile-prefix-map=$BUILD=/build" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 >/dev/null
cmake --build "$BUILD" 2>&1 | grep -E 'error:' || true
[ -x "$BUILD/BodySlide" ] || { echo "build failed"; exit 1; }

tmp="$OUT.new"; rm -rf "$tmp"; mkdir -p "$tmp"
cp "$BUILD/BodySlide" "$BUILD/OutfitStudio" "$tmp/"
cp -R "$SRC/res" "$SRC/lang" "$tmp/"
cp "$SRC/Config.xml" "$tmp/Config.default.xml"   # SkyrimMT writes Config.xml from this before every run
for f in RefTemplates.xml BuildSelection.xml; do [ -f "$SRC/$f" ] && cp "$SRC/$f" "$tmp/"; done
dylibbundler -cd -of -b -x "$tmp/BodySlide" -x "$tmp/OutfitStudio" -d "$tmp/libs" -p @executable_path/libs >/dev/null 2>&1
codesign -f -s - "$tmp/libs/"*.dylib "$tmp/BodySlide" "$tmp/OutfitStudio" 2>/dev/null
printf '%s %s %s\n' "$TAG" "$want" "$(cat "$PATCH" "$SELF" "$SKYRIMMT_ROOT/tools/bodyslide/third_party/bc7enc/"* | shasum -a 256 | cut -c1-16)" > "$tmp/.skyrimmt-bodyslide"   # build id: source, patch, build settings
rm -rf "$OUT"; mv "$tmp" "$OUT"
echo "BodySlide built: $OUT"
