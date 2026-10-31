#!/bin/bash
# Start Skyrim SE directly (SkyrimSE.exe, no Bethesda launcher) inside SkyrimMT's prefix. Steam must be logged on
# first (ensure_steam); the GOG version starts without any client. Returns once the game process is started; the
# session helper watches it from there.
#   scripts/skyrim.sh [args for SkyrimSE.exe]
# Environment:
#   SKYRIMMT_RENDERER=dxmt|dxvk     D3D11 layer (default dxmt = the runtime's builtin d3d11/dxgi)
#   SKYRIMMT_FRAMETRACE=<file.csv>  record Present timing (tools/frametrace proxy d3d11.dll; DXMT only)
#   SKYRIMMT_METAL_HUD=1            Metal performance HUD overlay
#   SKYRIMMT_USE_SKSE=0|1           start through skse64_loader.exe when SKSE is installed (default 1); the version
#                                   guard falls back to SkyrimSE.exe when SKSE was built for another game version
. "$(dirname "$0")/_env.sh"
mkdir -p "$SKYRIM_HOME/logs"; LOG="$SKYRIM_HOME/logs/skyrim.log"
[ -f "$GAMEDIR/SkyrimSE.exe" ] || { echo "Skyrim is not installed"; exit 1; }
if game_running; then echo "Skyrim is already running"; exit 0; fi

# steam_appid.txt makes SteamAPI_RestartAppIfNecessary return false, so SkyrimSE.exe is not relaunched through
# Steam (which would open the Bethesda launcher). Steamworks docs: partner.steamgames.com/doc/sdk/api
if ! is_gog; then
  [ "$(cat "$GAMEDIR/steam_appid.txt" 2>/dev/null)" = "$SKYRIM_APPID" ] || printf '%s' "$SKYRIM_APPID" > "$GAMEDIR/steam_appid.txt"
fi

# DXMT stray-Release fix (PLAN S7): without it Skyrim aborts right after the Bethesda logo
DXMTP="$SKYRIMMT_ROOT/tools/wine-patches/dxmt_purevirtual_return.sh"
[ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" status)" = patched ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" apply >/dev/null

# Audio buffer 90 ms instead of 30 ms: no crackle with Microsoft's XAudio2 under the game's CPU load
AUDP="$SKYRIMMT_ROOT/tools/wine-patches/mmdevapi_buffer.sh"
[ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" status)" = patched ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" apply >/dev/null

# Audio mix rate (CrossOver's "audio sample rate"): Wine reports this rate instead of the device's, macOS converts.
# 96 kHz by default — 44.1 kHz devices crackle otherwise. Launcher Game tab → config/audio-mix-rate ("device" = Wine's own).
RATEP="$SKYRIMMT_ROOT/tools/wine-patches/coreaudio_rate.sh"
mix=$(tr -d '[:space:]' < "$SKYRIM_HOME/config/audio-mix-rate" 2>/dev/null); mix=${mix:-96000}
if [ "$mix" = device ]; then
  [ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" status)" = original ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" revert >/dev/null
else
  [ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" status)" = "patched-$mix" ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" apply "$mix" >/dev/null
fi

# Audio period 30 ms instead of 10 ms: Microsoft's XAudio2 writes one period per wake-up; 10 ms left the output running
# dry ~13 times a second (crackle, measured with tools/audiotap). See tools/wine-patches/coreaudio_period.sh.
PERP="$SKYRIMMT_ROOT/tools/wine-patches/coreaudio_period.sh"
[ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PERP" status)" = patched ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PERP" apply >/dev/null

ensure_winebus_options   # PlayStation controllers on macOS (see _env.sh)
ensure_audio_libs        # Microsoft XAudio2 for SkyrimSE.exe: correct sound distances (see _env.sh)
ensure_shader_compiler   # Microsoft d3dcompiler_47 for SkyrimSE.exe: Community Shaders / ENB compile (see _env.sh)
ensure_steam || { echo "Steam did not log on — open Steam (scripts/steam.sh --login)"; exit 1; }
follow_session_sync

# per-launch renderer files next to SkyrimSE.exe (removed again when not wanted; only files we put there)
place() {   # place <src|""> <name>: install src as $GAMEDIR/<name>, or remove our previous copy
  local dst="$GAMEDIR/$2" mark="$SKYRIM_HOME/run/placed-$2"
  if [ -n "$1" ]; then cp "$1" "$dst" && echo "$1" > "$mark"
  elif [ -f "$mark" ]; then rm -f "$dst" "$mark"; fi
}
ovr="${WINEDLLOVERRIDES:-}"
case "${SKYRIMMT_RENDERER:-dxmt}" in
  dxmt)
    place "" dxgi.dll
    if [ -n "${SKYRIMMT_FRAMETRACE:-}" ]; then
      place "$SKYRIMMT_ROOT/build/frametrace/d3d11.dll" d3d11.dll
      ovr="$ovr;d3d11=n,b"
      export FRAMETRACE_OUT="Z:$(echo "$SKYRIMMT_FRAMETRACE" | tr '/' '\\')"
    else place "" d3d11.dll; fi ;;
  dxvk)
    place "$SKYRIM_HOME/wine/share/dxvk/x86_64-windows/d3d11.dll" d3d11.dll
    place "$SKYRIM_HOME/wine/share/dxvk/x86_64-windows/dxgi.dll" dxgi.dll
    ovr="$ovr;d3d11,dxgi=n" ;;
  *) echo "unknown SKYRIMMT_RENDERER"; exit 2 ;;
esac
[ "${SKYRIMMT_METAL_HUD:-0}" = 1 ] && export MTL_HUD_ENABLED=1
# SSE Engine Fixes part 2 (and other preloaders) ship a d3dx9_42.dll / tbb DLLs for the game folder: Wine prefers its
# own builtin d3dx9_42, so a DLL next to SkyrimSE.exe needs a native-first override to be loaded at all.
for d in d3dx9_42 tbb tbbmalloc; do
  [ -f "$GAMEDIR/$d.dll" ] && ovr="$ovr;$d=n,b"
done

# Display: a borderless window on macOS for every profile (exclusive fullscreen misbehaves under Wine; modlists made
# on Windows often ship bBorderless=0, a bordered window). Size from the launcher's Game tab (config/window-size):
# "fit" (default) = the screen, "WxH" = that size (never larger than the screen), "keep" = the profile's INI as is.
prefs="$MYGAMES_DIR/SkyrimPrefs.ini"
wsize=$(tr -d '[:space:]' < "$SKYRIM_HOME/config/window-size" 2>/dev/null); wsize=${wsize:-fit}
if [ -f "$prefs" ] && [ "$wsize" != keep ]; then
  . "$SKYRIMMT_ROOT/scripts/ini.sh"
  [ "$(ini_get "$prefs" Display bBorderless)" = 1 ] || ini_set "$prefs" Display bBorderless 1
  [ "$(ini_get "$prefs" Display "bFull Screen")" = 0 ] || ini_set "$prefs" Display "bFull Screen" 0
  ds=$("$SKYRIMMT_ROOT/build/tools/displaystate" 2>/dev/null)
  dw=$(echo "$ds" | sed -n 's/.* w=\([0-9]*\).*/\1/p'); dh=$(echo "$ds" | sed -n 's/.* h=\([0-9]*\).*/\1/p')
  if [ -n "$dw" ] && [ -n "$dh" ]; then
    case $wsize in
      *x*) ww=${wsize%x*}; wh=${wsize#*x}; [ "$ww" -gt "$dw" ] && ww=$dw; [ "$wh" -gt "$dh" ] && wh=$dh ;;
      *)   ww=$dw; wh=$dh ;;
    esac
    [ "$(ini_get "$prefs" Display "iSize W")" = "$ww" ] || ini_set "$prefs" Display "iSize W" "$ww"
    [ "$(ini_get "$prefs" Display "iSize H")" = "$wh" ] || ini_set "$prefs" Display "iSize H" "$wh"
  fi
fi

cd "$GAMEDIR" || exit 1
exe=SkyrimSE.exe
if [ "${SKYRIMMT_USE_SKSE:-1}" = 1 ] && [ -f skse64_loader.exe ]; then
  gv=$("$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/^game_version=//p'); gv=${gv%.0}
  sv=$("$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/.*skse_for=//p')
  if [ -n "$sv" ] && [ "$sv" = "$gv" ]; then exe=skse64_loader.exe
  else echo "SKSE is for Skyrim ${sv:-?}, the game is $gv — starting without SKSE"; fi
fi
echo "== $(date '+%F %T') $exe renderer=${SKYRIMMT_RENDERER:-dxmt} trace=${SKYRIMMT_FRAMETRACE:-off} $*" >> "$LOG"
WINEDLLOVERRIDES="${ovr#;}" "$WINE" "$exe" "$@" >> "$LOG" 2>&1 &
disown
for _ in $(seq 45); do game_running && { echo "Skyrim started ($exe)"; exit 0; }; sleep 1; done   # the loader starts SkyrimSE.exe
echo "Skyrim did not start — see $LOG"; exit 1
