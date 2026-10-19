# Shared environment for all SkyrimMT scripts. Self-contained: works from a git checkout or from inside
# SkyrimMT.app (scripts are bundled). The game environment location is configurable via SKYRIM_HOME.
_skmt_src="${BASH_SOURCE[0]:-}"
[ -z "$_skmt_src" ] && [ -n "${ZSH_VERSION:-}" ] && eval '_skmt_src="${(%):-%x}"'   # sourced from zsh
SKYRIMMT_ROOT="$(cd "$(dirname "$_skmt_src")/.." && pwd)"; export SKYRIMMT_ROOT; unset _skmt_src
export SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
export WINEPREFIX="$SKYRIM_HOME/prefix"
export WINE="$SKYRIM_HOME/wine/bin/wine"
export WINESERVER="$SKYRIM_HOME/wine/bin/wineserver"
export STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
export STEAM_GAMEDIR="$STEAM_DIR/steamapps/common/Skyrim Special Edition"   # Steam's install (kept as Steam updates it)
# The game folder Play uses: Steam's install, or a pinned version from the version switcher (scripts/versions.sh).
# An explicit GAMEDIR from the caller wins (tools that inspect a specific folder).
_skmt_v=$(cat "$SKYRIM_HOME/config/game-version" 2>/dev/null)
if [ -z "${GAMEDIR:-}" ]; then
  if [ -n "$_skmt_v" ] && [ -f "$SKYRIM_HOME/versions/$_skmt_v/.skyrimmt-version" ]; then export GAMEDIR="$SKYRIM_HOME/versions/$_skmt_v"
  else export GAMEDIR="$STEAM_GAMEDIR"; fi
fi
unset _skmt_v
export SKYRIM_APPID=489830
# per-user game folders inside the prefix (the prefix user is the Mac user name)
_skmt_user="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}"
export MYGAMES_DIR="$_skmt_user/Documents/My Games/Skyrim Special Edition"   # Skyrim*.ini, Saves/
export LOCALAPPDATA_DIR="$_skmt_user/AppData/Local/Skyrim Special Edition"    # plugins.txt
unset _skmt_user
export DYLD_FALLBACK_LIBRARY_PATH="$SKYRIM_HOME/wine/lib:/usr/lib"   # FreeType etc. (lost if launched via SIP binaries like nohup)
export WINEDEBUG="${WINEDEBUG:--all}"
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-0}"
# No Wine crash debugger: after a crash winedbg stays attached to the dead game, keeping processes alive and
# blocking the next start. Steam still writes crash dumps.
case "${WINEDLLOVERRIDES:-}" in *winedbg*) ;; *) export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}winedbg.exe=d" ;; esac

# PIDs of Windows processes of a Wine runtime whose argv[0] (up to ".exe": a bare "steam.exe" or a full C:\… path)
# matches $1 (ERE, case-insensitive). argv[0] may contain spaces (C:\Program Files (x86)\…), so it is cut at ".exe".
# Ownership = which runtime's ntdll.so the process maps ($2, default ours). `ps eww` can't be used: Wine rewrites the
# argv area of Windows processes, so their environment (WINEPREFIX) isn't visible. SkyrimMT's runtime is its own
# file (APFS clone), so tf2mt's processes never match ours and vice versa.
NTDLL="$SKYRIM_HOME/wine/lib/wine/x86_64-unix/ntdll.so"
win_pids() {
  local c; c=$(LC_ALL=C pgrep -fil "$1" | RE="$1" LC_ALL=C awk '{ re = ENVIRON["RE"]
      pid = $1; sub(/^[0-9]+ /, ""); i = index(tolower($0), ".exe"); if (!i) next
      a0 = tolower(substr($0, 1, i + 3)); if (a0 ~ ("(^|\\\\)(" tolower(re) ")$")) print pid }')
  [ -n "$c" ] || return 0
  lsof -t "${2:-$NTDLL}" 2>/dev/null | sort -u | grep -Fx -f <(echo "$c")
}
game_pids()     { win_pids 'SkyrimSE\.exe'; }
loader_pids()   { win_pids 'skse64_loader\.exe|SkyrimSELauncher\.exe'; }   # start the game, then exit
game_running()  { [ -n "$(game_pids)" ]; }
loader_running(){ [ -n "$(loader_pids)" ]; }
steam_running() { [ -n "$(win_pids 'steam\.exe')" ]; }
server_up()     { pgrep -f "$SKYRIM_HOME/wine/.*wineserver" >/dev/null; }

# tf2mt's Steam (same Steam account → "playing on another device" conflicts, PLAN §4.2). Never kill it from here:
# the launcher offers to close that session through tf2mt's own scripts/session-end.sh.
TF2MT_NTDLL="${TF2_HOME:-$HOME/Games/tf2}/wine/lib/wine/x86_64-unix/ntdll.so"
other_steam_pids() { [ -f "$TF2MT_NTDLL" ] && win_pids 'steam\.exe' "$TF2MT_NTDLL"; }

# Start Steam if needed and wait for a NEW "Logged On" line (old lines from earlier sessions don't count). The game
# must not start before Steam has logged on (tf2mt: crash during load).
ensure_steam() {
  steam_running && return 0
  local n; n=$(wc -l < "$STEAM_DIR/logs/connection_log.txt" 2>/dev/null | tr -d ' '); n=${n:-0}
  "$SKYRIMMT_ROOT/scripts/steam.sh" >/dev/null
  for _ in $(seq 120); do
    tail -n +$((n + 1)) "$STEAM_DIR/logs/connection_log.txt" 2>/dev/null | grep -q 'Logged On' && { sleep 8; return 0; }
    sleep 2
  done
  return 1
}

# msync must match the running wineserver, otherwise a joining process exits silently. steam.sh / run-exe.sh
# record the session's mode when they start a new wineserver; later processes follow it.
SESSION_SYNC="$SKYRIM_HOME/run/wine-session-sync"
# Wine's controller driver prefers "hidraw" for PlayStation pads (DualShock 4, DualSense) and drops their SDL device —
# but hidraw only exists on Linux (udev), so on macOS those pads vanished for games. DisableHidraw keeps the SDL path
# (SDL maps them to XInput). docs/m11-controllers.md. Idempotent; adds the value to prefixes made before this fix.
ensure_winebus_options() {
  grep -q '"DisableHidraw"=dword:00000001' "$WINEPREFIX/system.reg" 2>/dev/null && return 0
  "$WINE" reg add 'HKLM\System\CurrentControlSet\Services\winebus' /v DisableHidraw /t REG_DWORD /d 1 /f >/dev/null 2>&1
}
# Audio: Wine's builtin XAudio2 (FAudio) breaks Skyrim's distance attenuation — voices sound far away until you stand
# next to the NPC, distant sounds jump to full volume (Wine bugs 45311 / 47088). Skyrim SE loads XAudio2_7 and
# X3DAudio1_7: use Microsoft's own (DirectX June 2010 redistributable, downloaded from Microsoft and checked like
# winetricks' xact_x64) for SkyrimSE.exe only. config/audio = builtin switches back (settings.sh audio builtin).
DXREDIST_URL="https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"
DXREDIST_SHA256="053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"
XAUDIO_DLLS="xaudio2_7.dll:f8636ccc37bbfc84107992b60e4226eb7237417112267ed64b08f72983ac4314 x3daudio1_7.dll:9460709339701ad471a5cabe6365355f4d586dc4fcb86507c1331839dc555446 xapofx1_5.dll:e47dcf74d50403b376c562e4121e359e5886e42fcc60b3fa8ba53e6826854c49"
audio_mode() { cat "$SKYRIM_HOME/config/audio" 2>/dev/null || echo native; }
native_xaudio_files() {   # extract the three DLLs into $SKYRIM_HOME/cache/directx/dll (download once)
  local d="$SKYRIM_HOME/cache/directx" exe="$SKYRIM_HOME/cache/directx/directx_Jun2010_redist.exe"
  mkdir -p "$d/dll" "$d/cab"
  local ok=1 e; for e in $XAUDIO_DLLS; do [ "$(shasum -a 256 "$d/dll/${e%%:*}" 2>/dev/null | cut -d' ' -f1)" = "${e#*:}" ] || ok=0; done
  [ $ok = 1 ] && return 0
  if [ "$(shasum -a 256 "$exe" 2>/dev/null | cut -d' ' -f1)" != "$DXREDIST_SHA256" ]; then
    curl -sfL --retry 2 -o "$exe.part" "$DXREDIST_URL" || return 1
    [ "$(shasum -a 256 "$exe.part" | cut -d' ' -f1)" = "$DXREDIST_SHA256" ] || { rm -f "$exe.part"; return 1; }
    mv "$exe.part" "$exe"
  fi
  bsdtar -xf "$exe" -C "$d/cab" Jun2010_XAudio_x64.cab Feb2010_X3DAudio_x64.cab || return 1
  bsdtar -xf "$d/cab/Jun2010_XAudio_x64.cab" -C "$d/cab" XAudio2_7.dll XAPOFX1_5.dll || return 1
  bsdtar -xf "$d/cab/Feb2010_X3DAudio_x64.cab" -C "$d/cab" X3DAudio1_7.dll || return 1
  cp "$d/cab/XAudio2_7.dll" "$d/dll/xaudio2_7.dll"; cp "$d/cab/X3DAudio1_7.dll" "$d/dll/x3daudio1_7.dll"; cp "$d/cab/XAPOFX1_5.dll" "$d/dll/xapofx1_5.dll"
  for e in $XAUDIO_DLLS; do [ "$(shasum -a 256 "$d/dll/${e%%:*}" | cut -d' ' -f1)" = "${e#*:}" ] || return 1; done
}
ensure_audio_libs() {
  local sys="$WINEPREFIX/drive_c/windows/system32" keep="$SKYRIM_HOME/backups/wine-xaudio" e n key='HKCU\Software\Wine\AppDefaults\SkyrimSE.exe\DllOverrides'
  if [ "$(audio_mode)" = builtin ]; then
    for e in $XAUDIO_DLLS; do n=${e%%:*}; [ -f "$keep/$n" ] && cp "$keep/$n" "$sys/$n"; done
    grep -q 'AppDefaults\\\\SkyrimSE.exe\\\\DllOverrides' "$WINEPREFIX/user.reg" 2>/dev/null && "$WINE" reg delete "$key" /f >/dev/null 2>&1
    return 0
  fi
  native_xaudio_files || { echo "INFO audio: Microsoft XAudio2 not available (offline?) — using Wine's" >&2; return 0; }
  mkdir -p "$keep"
  for e in $XAUDIO_DLLS; do
    n=${e%%:*}
    [ "$(shasum -a 256 "$sys/$n" 2>/dev/null | cut -d' ' -f1)" = "${e#*:}" ] && continue
    [ -f "$sys/$n" ] && cp "$sys/$n" "$keep/$n"          # Wine's own, for "audio builtin"
    cp "$SKYRIM_HOME/cache/directx/dll/$n" "$sys/$n"
  done
  grep -q '"xaudio2_7"="native,builtin"' "$WINEPREFIX/user.reg" 2>/dev/null && return 0
  for n in xaudio2_7 x3daudio1_7 xapofx1_5; do "$WINE" reg add "$key" /v "$n" /t REG_SZ /d native,builtin /f >/dev/null 2>&1; done
}
# Shader compiler: Wine's builtin d3dcompiler_47 (vkd3d-shader) can't compile modern HLSL — Community Shaders reported
# "5440 shaders failed to compile" (E5005 GetDimensions on RWTexture2D, A Dragonborn's Fate). Microsoft's own
# d3dcompiler_47 ("for Redistribution", 6.3.9600.16384, the file winetricks d3dcompiler_47 uses, from the Windows SDK
# cabinet on download.microsoft.com) for SkyrimSE.exe only. config/d3dcompiler = builtin switches back.
D3DC_CAB_URL="https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/61d57a7a82309cd161a854a6f4619e52.cab"
D3DC_CAB_SHA256="f736e161547095bb8d98c636b85fdfeb4070fefeee3c3745db3ce88f6eb1d9de"
D3DC_DLL_SHA256="e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4"
ensure_shader_compiler() {
  local sys="$WINEPREFIX/drive_c/windows/system32" d="$SKYRIM_HOME/cache/d3dcompiler" keep="$SKYRIM_HOME/backups/wine-d3dcompiler"
  local key='HKCU\Software\Wine\AppDefaults\SkyrimSE.exe\DllOverrides'
  if [ "$(cat "$SKYRIM_HOME/config/d3dcompiler" 2>/dev/null || echo native)" = builtin ]; then
    [ -f "$keep/d3dcompiler_47.dll" ] && cp "$keep/d3dcompiler_47.dll" "$sys/d3dcompiler_47.dll"
    "$WINE" reg delete "$key" /v d3dcompiler_47 /f >/dev/null 2>&1; return 0
  fi
  [ "$(shasum -a 256 "$sys/d3dcompiler_47.dll" 2>/dev/null | cut -d' ' -f1)" = "$D3DC_DLL_SHA256" ] && grep -q '"d3dcompiler_47"="native,builtin"' "$WINEPREFIX/user.reg" 2>/dev/null && return 0
  mkdir -p "$d"
  if [ "$(shasum -a 256 "$d/d3dcompiler_47.dll" 2>/dev/null | cut -d' ' -f1)" != "$D3DC_DLL_SHA256" ]; then
    if [ "$(shasum -a 256 "$d/sdk64.cab" 2>/dev/null | cut -d' ' -f1)" != "$D3DC_CAB_SHA256" ]; then
      curl -sfL --retry 2 -o "$d/sdk64.cab.part" "$D3DC_CAB_URL" || { echo "INFO shaders: Microsoft's compiler not available (offline?) — using Wine's" >&2; return 0; }
      [ "$(shasum -a 256 "$d/sdk64.cab.part" | cut -d' ' -f1)" = "$D3DC_CAB_SHA256" ] || { rm -f "$d/sdk64.cab.part"; return 0; }
      mv "$d/sdk64.cab.part" "$d/sdk64.cab"
    fi
    bsdtar -xf "$d/sdk64.cab" -C "$d" fil3585cb2ea5db13cc0838f8d06b5c9679 && mv "$d/fil3585cb2ea5db13cc0838f8d06b5c9679" "$d/d3dcompiler_47.dll"
    [ "$(shasum -a 256 "$d/d3dcompiler_47.dll" 2>/dev/null | cut -d' ' -f1)" = "$D3DC_DLL_SHA256" ] || return 0
  fi
  mkdir -p "$keep"
  if [ "$(shasum -a 256 "$sys/d3dcompiler_47.dll" 2>/dev/null | cut -d' ' -f1)" != "$D3DC_DLL_SHA256" ]; then
    [ -f "$sys/d3dcompiler_47.dll" ] && [ ! -f "$keep/d3dcompiler_47.dll" ] && cp "$sys/d3dcompiler_47.dll" "$keep/d3dcompiler_47.dll"
    cp "$d/d3dcompiler_47.dll" "$sys/d3dcompiler_47.dll"
  fi
  "$WINE" reg add "$key" /v d3dcompiler_47 /t REG_SZ /d native,builtin /f >/dev/null 2>&1
}
record_session_sync() { mkdir -p "$SKYRIM_HOME/run"; [ "${WINEMSYNC:-0}" = 1 ] && echo msync > "$SESSION_SYNC" || echo none > "$SESSION_SYNC"; }
follow_session_sync() {
  if server_up && [ -f "$SESSION_SYNC" ]; then
    if [ "$(cat "$SESSION_SYNC")" = msync ]; then export WINEMSYNC=1; else unset WINEMSYNC; fi
  fi
}
