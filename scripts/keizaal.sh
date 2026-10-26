#!/bin/bash
# Keizaal Online (multiplayer RP server, github.com/skyrim-roleplay): start its launcher (Electron) in SkyrimMT's prefix.
#   scripts/keizaal.sh               Steam first, then the launcher (its Play starts skse64_loader.exe itself)
#   scripts/keizaal.sh <skyrim-rp://…>   hand the Discord login callback to the launcher (macOS opens these with SkyrimMT)
# Steam must run first: SkyrimSE.exe's Steam DRM restarts the game through Steam (without SKSE) otherwise.
# --in-process-gpu: DXMT can't show Chromium's cross-process swap chain, the launcher window would stay invisible.
. "$(dirname "$0")/_env.sh"
EXE="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/AppData/Local/Programs/skyrim-rp-launcher/keizaal-online.exe"
[ -f "$EXE" ] || { echo "Keizaal Online's launcher isn't installed in $WINEPREFIX"; exit 1; }

if [ "${1:-}" ]; then   # login callback: a running launcher gets it (single instance), else it starts with it
  case "$1" in skyrim-rp://*) exec "$SKYRIMMT_ROOT/scripts/run-exe.sh" "$EXE" "$1" ;; *) echo "not a skyrim-rp:// link"; exit 2 ;; esac
fi

RUN="$SKYRIM_HOME/run"; mkdir -p "$RUN"
for _ in $(seq 45); do p=$(cat "$RUN/teardown.lock/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null || break; sleep 1; done
for _ in $(seq 120); do [ -d "$RUN/deploy.lock" ] || break; sleep 1; done
[ -z "$(other_steam_pids)" ] || { echo "tf2mt's Steam is running with the same account — close it first."; exit 1; }

if ! game_running; then
  # Keizaal's NirnLabUIPlatform with CPU frames under Wine (tools/keizaal/README.md): only over the exact DLL Keizaal
  # ships, never over another version
  nl="$GAMEDIR/Data/NirnLabUIPlatform/NirnLabUIPlatform.dll"
  if [ "$(shasum -a 256 "$nl" 2>/dev/null | cut -c1-64)" = b2f564afc796ed7c07c3a2993d229fa13aa20b1fc9ba23767229adc1519d13cf ]; then
    cp "$SKYRIMMT_ROOT/tools/keizaal/NirnLabUIPlatform.dll" "$nl" && echo "in-game UI: NirnLabUIPlatform with CPU frames"
  fi
  # Keizaal's UI asks for its fonts at /assets/… from a file:// page (the drive root): relative paths find them
  css="$GAMEDIR/Data/Platform/UI/assets/app.css"
  grep -q 'url(/assets/' "$css" 2>/dev/null && sed -i '' 's#url(/assets/#url(./#g' "$css" && echo "in-game UI: font paths fixed"
fi

ensure_steam || { echo "Steam did not log on — open Steam (scripts/steam.sh --login)"; exit 1; }
"$SKYRIMMT_ROOT/scripts/run-exe.sh" "$EXE" --in-process-gpu
