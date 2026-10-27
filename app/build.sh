#!/bin/bash
# Build SkyrimMT.app (native SwiftUI launcher) and install it to /Applications (--no-install to only build).
# The app is self-contained and redistributable: it bundles the SkyrimMT scripts/configs/patch tools and an original
# icon. No Bethesda or Valve content is bundled — Skyrim's art is loaded at runtime from the user's Steam library cache.
set -euo pipefail
cd "$(dirname "$0")"; ROOT="$(cd .. && pwd)"
OUT="$ROOT/build/app"; APP="$OUT/SkyrimMT.app"; RES="$APP/Contents/Resources"
VERSION="${SKYRIMMT_VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)}"
case $VERSION in v[0-9]*) ;; *) VERSION="0.0.0-dev" ;; esac   # no tag yet: a dev build never looks newer than a release
if [ "${1:-}" != --no-install ]; then
  pgrep -x SkyrimMT >/dev/null && { echo "quit SkyrimMT first"; exit 1; }
  ROOT_ENV="$ROOT/scripts/_env.sh"; ( . "$ROOT_ENV"; game_running ) && { echo "quit Skyrim first"; exit 1; }
fi
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$RES/skyrimmt/tools"
swiftc -O -parse-as-library -target arm64-apple-macos13 SkyrimMT.swift ModManager.swift ModsPage.swift HealthPage.swift CrashPage.swift SavesPage.swift PluginsPage.swift ActivityView.swift CleaningUI.swift Undo.swift GetStarted.swift DownloadQueue.swift BrowsePage.swift IniEditor.swift Notify.swift SnapshotsPage.swift PerfPage.swift EssentialsInstall.swift DataPage.swift Controllers.swift ModKit/*.swift -o "$APP/Contents/MacOS/SkyrimMT"
swift make_icon.swift "$OUT/SkyrimMT.iconset" "$OUT/icon-preview.png"
iconutil -c icns "$OUT/SkyrimMT.iconset" -o "$RES/SkyrimMT.icns"
# bundled SkyrimMT: only what the launcher runs (scripts, configs, wine patch tools, licence notes)
cp -R "$ROOT/scripts" "$ROOT/config" "$RES/skyrimmt/"
cp -R "$ROOT/tools/wine-patches" "$ROOT/tools/keizaal" "$RES/skyrimmt/tools/"
cp "$ROOT/THIRD_PARTY.md" "$RES/skyrimmt/"
# unattended benchmark (Mod Manager → Performance): the script + its keyboard/display helpers
mkdir -p "$RES/skyrimmt/tools/bench" "$RES/skyrimmt/build/tools"
cp "$ROOT/tools/bench/bench.sh" "$ROOT/tools/bench/analyze.py" "$ROOT/tools/bench/ini_merge.py" "$RES/skyrimmt/tools/bench/"
swiftc -O "$ROOT/tools/bench/gamekeys.swift" -o "$RES/skyrimmt/build/tools/gamekeys"
clang -O2 "$ROOT/tools/bench/displaystate.c" -framework CoreGraphics -framework IOKit -framework CoreFoundation -o "$RES/skyrimmt/build/tools/displaystate"
# frame-time recording proxy (Debug → Record frame times)
if command -v x86_64-w64-mingw32-gcc >/dev/null || [ -x /opt/homebrew/bin/x86_64-w64-mingw32-gcc ]; then
  mkdir -p "$RES/skyrimmt/build/frametrace"
  PATH="/opt/homebrew/bin:$PATH" x86_64-w64-mingw32-gcc -O2 -shared -o "$RES/skyrimmt/build/frametrace/d3d11.dll" \
    "$ROOT/tools/frametrace/frametrace.c" -ld3d11 -static-libgcc
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SkyrimMT</string>
  <key>CFBundleDisplayName</key><string>SkyrimMT</string>
  <key>CFBundleIdentifier</key><string>local.skyrimmt.launcher</string>
  <key>NSMicrophoneUsageDescription</key><string>Games running in SkyrimMT can use the microphone for voice chat (Keizaal Online, SkyMP).</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SkyrimMT</string>
  <key>CFBundleIconFile</key><string>SkyrimMT</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Nexus Mods download</string>
    <key>CFBundleURLSchemes</key><array><string>nxm</string></array>
  </dict><dict>
    <key>CFBundleURLName</key><string>Keizaal Online login</string>
    <key>CFBundleURLSchemes</key><array><string>skyrim-rp</string></array>
  </dict></array>
</dict></plist>
PLIST
# LOOT helper (separate GPL-3 program, helpers/loot): built with cargo when Rust is installed
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
# --remap-path-prefix: no build-machine paths (home folder, crate registry) inside the shipped binary
if [ -x "$CARGO" ] && (cd "$ROOT/helpers/loot" && RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$ROOT=." "$CARGO" build --release -q 2>/dev/null); then
  mkdir -p "$APP/Contents/Helpers" "$RES/skyrimmt/helpers/loot"
  cp "$ROOT/helpers/loot/target/release/skyrimmt-loot" "$APP/Contents/Helpers/skyrimmt-loot"
  cp "$ROOT/helpers/loot/LICENSE" "$ROOT/helpers/loot/README.md" "$RES/skyrimmt/helpers/loot/"
else
  echo "WARNING: LOOT helper not built (no Rust toolchain); the Plugins page falls back to the basic sort" >&2
fi
# invisible session helper app (macOS 27: Steam/Wine/Skyrim must not be attributed to the launcher)
# Keychain helper: built once per source change and reused byte-for-byte, so its code hash stays the same across app
# builds and the Keychain's "Always Allow" for it lasts (app/KeyHelper/main.swift explains why).
KH_SRC="$ROOT/app/KeyHelper/main.swift"; KH_HASH=$(shasum -a 256 "$KH_SRC" | cut -c1-16)
KH_CACHE="$ROOT/build/keyhelper/$KH_HASH/skyrimmt-keyhelper"
if [ ! -x "$KH_CACHE" ]; then
  mkdir -p "$(dirname "$KH_CACHE")"
  swiftc -O -target arm64-apple-macos13 "$KH_SRC" -o "$KH_CACHE"
fi
mkdir -p "$APP/Contents/Helpers"; cp "$KH_CACHE" "$APP/Contents/Helpers/skyrimmt-keyhelper"

# built-in fixes deployed with every profile (ModKit.builtinMods): Mac Fixes SKSE plugin (needs mingw-w64)
if command -v x86_64-w64-mingw32-gcc >/dev/null && "$ROOT/tools/skse-macfixes/build.sh" >/dev/null; then
  mkdir -p "$RES/builtin/SkyrimMT Mac Fixes/SKSE/Plugins"
  cp "$ROOT/build/skse/SkyrimMT_MacFixes.dll" "$RES/builtin/SkyrimMT Mac Fixes/SKSE/Plugins/"
  # dated like its source: rebuilding the app doesn't make every profile "changed" (deploy compares size + date)
  touch -r "$ROOT/tools/skse-macfixes/macfixes.c" "$RES/builtin/SkyrimMT Mac Fixes/SKSE/Plugins/SkyrimMT_MacFixes.dll"
else echo "warning: mingw-w64 missing — Mac Fixes SKSE plugin not bundled"; fi
# controller probe for the launcher (what Skyrim's XInput sees; scripts/controllers.sh)
if command -v x86_64-w64-mingw32-gcc >/dev/null && "$ROOT/tools/xinputprobe/build.sh" >/dev/null; then
  cp "$ROOT/build/xinputprobe/xinputprobe.exe" "$RES/skyrimmt/tools/"
else echo "warning: mingw-w64 missing — controller probe not bundled"; fi
SES="$APP/Contents/Helpers/SkyrimMT Session.app"; mkdir -p "$SES/Contents/MacOS"
swiftc -O -target arm64-apple-macos13 Session/SkyrimMTSession.swift -o "$SES/Contents/MacOS/skyrimmt-session"
cat > "$SES/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SkyrimMT Session</string>
  <key>CFBundleIdentifier</key><string>local.skyrimmt.session</string>
  <key>NSMicrophoneUsageDescription</key><string>Games running in SkyrimMT can use the microphone for voice chat (Keizaal Online, SkyMP).</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>skyrimmt-session</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# Stable signing identity (self-made, in its own keychain) when available: the designated requirement then stays the
# same across builds, so macOS keeps the Keychain "Always Allow" for the Nexus API key (ad-hoc changes every build).
SIGN_KC="$HOME/Library/Keychains/skyrimmt-signing.keychain-db"; SIGN_PW="$ROOT/build/.signing-keychain-pass"
if [ -f "$SIGN_KC" ] && [ -f "$SIGN_PW" ] && security unlock-keychain -p "$(cat "$SIGN_PW")" "$SIGN_KC" 2>/dev/null \
   && ID=$(security find-identity -p codesigning "$SIGN_KC" | awk '/SkyrimMT Code Signing/ {print $2; exit}') && [ -n "$ID" ]; then
  codesign -f -s "$ID" --keychain "$SIGN_KC" --deep "$APP" >/dev/null 2>&1 || { echo "signing failed — falling back to ad-hoc"; codesign -f -s - --deep "$APP" >/dev/null 2>&1; }
else
  codesign -f -s - --deep "$APP" >/dev/null 2>&1
fi
(cd "$OUT" && ditto -c -k --keepParent SkyrimMT.app SkyrimMT-app.zip)   # release asset
echo "built $APP  (+ $OUT/SkyrimMT-app.zip)"
if [ "${1:-}" != --no-install ]; then
  rm -rf "/Applications/SkyrimMT.app"; ditto "$APP" "/Applications/SkyrimMT.app"   # ditto keeps file dates (deploy compares them)
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SkyrimMT.app
  echo "installed /Applications/SkyrimMT.app"
fi
