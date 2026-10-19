#!/bin/bash
# Start Skyrim SE directly (SkyrimSE.exe, no Bethesda launcher) inside SkyrimMT's prefix. Steam must be logged on
# first (ensure_steam). Returns once the game process is started; the session helper watches it from there.
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
[ "$(cat "$GAMEDIR/steam_appid.txt" 2>/dev/null)" = "$SKYRIM_APPID" ] || printf '%s' "$SKYRIM_APPID" > "$GAMEDIR/steam_appid.txt"

# DXMT stray-Release fix (PLAN S7): without it Skyrim aborts right after the Bethesda logo
DXMTP="$SKYRIMMT_ROOT/tools/wine-patches/dxmt_purevirtual_return.sh"
[ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" status)" = patched ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" apply >/dev/null

# Audio buffer 90 ms instead of 30 ms: no crackle with Microsoft's XAudio2 under the game's CPU load
AUDP="$SKYRIMMT_ROOT/tools/wine-patches/mmdevapi_buffer.sh"
[ "$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" status)" = patched ] || SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" apply >/dev/null

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
