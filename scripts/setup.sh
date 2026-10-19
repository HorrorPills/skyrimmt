#!/bin/bash
# SkyrimMT setup — idempotent: every step checks first and skips what is already done.
#   scripts/setup.sh [--runtime <path-or-url to tf2mt-runtime-*.tar.xz>]
# Steps: Rosetta → Wine runtime → mouse patch → prefix (Windows 10) → Steam (Windows) → INI defaults →
#        Steam login / Skyrim install (TODO for the user, done from the launcher).
# Output lines starting with "==>" are step headers, "OK"/"SKIP"/"FAIL"/"TODO" are results, "DONE" ends a run
# (parsed by the launcher).
set -u
. "$(dirname "$0")/_env.sh"
. "$SKYRIMMT_ROOT/config/release.conf" 2>/dev/null || true   # RUNTIME_VERSION / RUNTIME_URL / RUNTIME_SHA256

RUNTIME_SRC="${SKYRIMMT_RUNTIME:-}"
TF2_RUNTIME="${TF2_HOME:-$HOME/Games/tf2}/wine"   # tf2mt's runtime: cloned (instant, no extra space) if same version
while [ $# -gt 0 ]; do
  case $1 in --runtime) RUNTIME_SRC=$2; shift 2 ;; *) echo "unknown option $1"; exit 2 ;; esac
done

step() { echo "==> $1"; }
ok()   { echo "OK   $1"; }
skip() { echo "SKIP $1"; }
todo() { echo "TODO $1"; }
fail() { echo "FAIL $1"; exit 1; }

mkdir -p "$SKYRIM_HOME"/{logs,config,cache,backups,run,mods,downloads,profiles}
PATCH="$SKYRIMMT_ROOT/tools/wine-patches/winemac_warp_nodiscard.sh"

step "Rosetta 2"
if [ -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]; then skip "installed"
else
  softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 \
    && ok "installed" || fail "could not install Rosetta — run: softwareupdate --install-rosetta --agree-to-license"
fi

step "Wine runtime ($SKYRIM_HOME/wine)"
if [ -x "$WINE" ]; then skip "present ($("$WINE" --version 2>/dev/null))"
else
  stage="$SKYRIM_HOME/wine.part"; rm -rf "$stage"
  if [ -z "$RUNTIME_SRC" ] && [ -x "$TF2_RUNTIME/bin/wine" ] && [ "$(cat "$TF2_RUNTIME/version" 2>/dev/null)" = "${RUNTIME_VERSION:-}" ]; then
    # Read-only use of tf2mt's runtime: APFS clone, then put back the ORIGINAL winemac.so (tf2mt patched its copy;
    # we patch ours ourselves below, with our own backup)
    cp -cR "$TF2_RUNTIME" "$stage" || fail "could not clone $TF2_RUNTIME"
    so="lib/wine/x86_64-unix/winemac.so"
    [ -f "$stage/$so" ] || { rm -rf "$stage"; fail "cloned runtime has no winemac.so"; }
    tf2orig="${TF2_HOME:-$HOME/Games/tf2}/backups/winemac.so.orig"
    [ -f "$tf2orig" ] && ! cmp -s "$tf2orig" "$stage/$so" && { cp "$tf2orig" "$stage/$so.new" && mv -f "$stage/$so.new" "$stage/$so"; }
    rm -f "$stage/lib/wine/x86_64-windows/tf2mt.dll" "$stage/lib/wine/x86_64-unix/tf2mt.so"   # tf2mt renderer, if a session left it
    mv "$stage" "$SKYRIM_HOME/wine"
    how="cloned from tf2mt ($TF2_RUNTIME)"
  else
    src="${RUNTIME_SRC:-${RUNTIME_URL:-}}"
    [ -n "$src" ] || fail "no runtime source — pass --runtime <tf2mt-runtime-*.tar.xz path or URL>"
    tarball="$src"
    if [[ $src == http* ]]; then
      tarball="$SKYRIM_HOME/cache/$(basename "$src")"
      if ! { [ -f "$tarball" ] && echo "${RUNTIME_SHA256:-x}  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; }; then
        echo "     downloading $src"
        curl -fsSL --retry 3 -o "$tarball.part" "$src" && mv "$tarball.part" "$tarball" || fail "download failed"
      fi
    fi
    if [ -n "${RUNTIME_SHA256:-}" ] && [ "$(basename "$tarball")" = "$(basename "${RUNTIME_URL:-}")" ]; then
      echo "$RUNTIME_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || fail "runtime checksum mismatch"
    fi
    mkdir -p "$stage.x" && tar -xJf "$tarball" -C "$stage.x" || { rm -rf "$stage.x"; fail "could not unpack $tarball"; }
    mv "$stage.x/wine" "$SKYRIM_HOME/wine" && rm -rf "$stage.x"
    how="unpacked $(basename "$tarball")"
  fi
  xattr -dr com.apple.quarantine "$SKYRIM_HOME/wine" 2>/dev/null
  [ -x "$WINE" ] && ok "$how ($("$WINE" --version))" || fail "runtime installed but $WINE missing"
fi

step "Smooth mouse fix (Wine patch)"
st=$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PATCH" status 2>&1)
case $st in
  patched*)  skip "already applied" ;;
  original*) SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PATCH" apply >/dev/null && ok "applied" || fail "patch failed" ;;
  *)         todo "this Wine build is not the tested one — patch not applied (mouse may feel choppy)" ;;
esac

step "Wine prefix ($WINEPREFIX)"
win10() { grep -q '"ProductName"="Windows 10' "$WINEPREFIX/system.reg" 2>/dev/null; }
if [ -f "$WINEPREFIX/system.reg" ] && win10; then skip "ready (Windows 10)"
else
  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE" wineboot -u >/dev/null 2>&1
    "$WINESERVER" -w
    [ -f "$WINEPREFIX/system.reg" ] || fail "wineboot did not create the prefix"
  fi
  win10 || { "$WINE" winecfg /v win10 >/dev/null 2>&1; "$WINESERVER" -w; }
  win10 && ok "created (Windows 10)" || fail "could not set Windows 10 mode"
fi

step "Game controllers (PlayStation pads through SDL)"
if grep -q '"DisableHidraw"=dword:00000001' "$WINEPREFIX/system.reg" 2>/dev/null; then skip "ready"
else ensure_winebus_options; "$WINESERVER" -w; grep -q '"DisableHidraw"=dword:00000001' "$WINEPREFIX/system.reg" && ok "set" || fail "could not set the controller option"; fi

step "Keep game files inside $SKYRIM_HOME"
# Wine links the prefix's Documents/Desktop/… to the Mac's real folders, so Skyrim's INIs and saves (My Games) would
# land in ~/Documents. SkyrimMT keeps everything in SKYRIM_HOME (PLAN §1): replace the links with real folders.
# Existing Skyrim settings/saves found through the old Documents link are clone-copied in (originals untouched).
udir="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}"; fixed=""
for d in Desktop Documents Downloads Music Pictures Videos; do
  [ -L "$udir/$d" ] || continue
  target=$(readlink "$udir/$d"); rm "$udir/$d" && mkdir -p "$udir/$d" || fail "could not replace the $d link"
  if [ "$d" = Documents ] && [ -d "$target/My Games/Skyrim Special Edition" ]; then
    mkdir -p "$udir/Documents/My Games" && cp -cpR "$target/My Games/Skyrim Special Edition" "$udir/Documents/My Games/" \
      || fail "could not copy Skyrim settings from $target"
    echo "     copied existing Skyrim settings/saves from $target/My Games (original left in place)"
  fi
  fixed="$fixed $d"
done
[ -n "$fixed" ] && ok "folders now inside the prefix:$fixed" || skip "already self-contained"

step "Skyrim crash fix for DXMT (stray Release)"
DXMTP="$SKYRIMMT_ROOT/tools/wine-patches/dxmt_purevirtual_return.sh"
st=$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" status 2>&1)
case $st in
  patched)  skip "already applied" ;;
  original|mixed) SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$DXMTP" apply >/dev/null && ok "applied" || fail "DXMT patch failed" ;;
  *)        todo "unknown DXMT build — fix not applied (Skyrim may quit after the logo)" ;;
esac

step "Audio without crackling (Wine audio buffer)"
AUDP="$SKYRIMMT_ROOT/tools/wine-patches/mmdevapi_buffer.sh"
st=$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" status 2>&1)
case $st in
  patched)  skip "already applied" ;;
  original|mixed) SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$AUDP" apply >/dev/null && ok "applied" || fail "audio buffer patch failed" ;;
  *)        todo "unknown Wine build — audio buffer unchanged (sound may crackle)" ;;
esac

step "Audio mix rate 96 kHz (Wine audio driver)"
RATEP="$SKYRIMMT_ROOT/tools/wine-patches/coreaudio_rate.sh"
st=$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" status 2>&1)
case $st in
  patched-*) skip "already applied (${st#patched-} Hz)" ;;
  original)  SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$RATEP" apply >/dev/null && ok "applied" || fail "audio mix rate patch failed" ;;
  *)         todo "unknown Wine build — mix rate unchanged (sound may crackle on 44.1 kHz devices)" ;;
esac

step "Audio without crackling (Wine audio period 30 ms)"
PERP="$SKYRIMMT_ROOT/tools/wine-patches/coreaudio_period.sh"
st=$(SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PERP" status 2>&1)
case $st in
  patched)  skip "already applied" ;;
  original) SKYRIM_HOME="$SKYRIM_HOME" /bin/bash "$PERP" apply >/dev/null && ok "applied" || fail "audio period patch failed" ;;
  *)        todo "unknown Wine build — audio period unchanged (sound may crackle)" ;;
esac

step "Steam for Windows"
if [ -f "$STEAM_DIR/steam.exe" ]; then skip "installed"
else
  inst="$SKYRIM_HOME/cache/SteamSetup.exe"
  curl -fsSL --retry 3 -o "$inst" https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe || fail "Steam installer download failed"
  "$WINE" "$inst" /S >/dev/null 2>&1      # NSIS silent install; the installer starts Steam afterwards
  for _ in $(seq 60); do [ -f "$STEAM_DIR/steam.exe" ] && break; sleep 2; done
  "$WINESERVER" -k 2>/dev/null           # stop the auto-started Steam (THIS prefix only); first login is via the launcher
  "$SKYRIMMT_ROOT/scripts/wine-sweep.sh" >/dev/null
  [ -f "$STEAM_DIR/steam.exe" ] && ok "installed" || fail "Steam installer did not finish"
fi

step "Skyrim settings folders + SkyrimMT INI defaults"
# Applied ONCE per game environment (marker) and never when the player already has a SkyrimCustom.ini of their own
# (PLAN §4.8, tf2mt's mastercomfig lesson). The user's Skyrim.ini / SkyrimPrefs.ini are never rewritten here.
mkdir -p "$MYGAMES_DIR/Saves" "$LOCALAPPDATA_DIR"
marker="$SKYRIM_HOME/config/ini-defaults-done"
if [ -f "$marker" ]; then skip "already applied once ($(cat "$marker"))"
elif [ -f "$MYGAMES_DIR/SkyrimCustom.ini" ]; then echo "own SkyrimCustom.ini" > "$marker"; skip "player has an own SkyrimCustom.ini — left alone"
else
  cp "$SKYRIMMT_ROOT/config/SkyrimCustom.ini" "$MYGAMES_DIR/SkyrimCustom.ini" || fail "could not write SkyrimCustom.ini"
  date '+%F' > "$marker"; ok "SkyrimCustom.ini written"
fi
# SkyrimPrefs.ini: only when the player has none yet (before the first launch) and the game is installed: the game's
# own default file with borderless window on (default is a bordered window, which doesn't fit a same-size screen).
prefs="$MYGAMES_DIR/SkyrimPrefs.ini"; pmarker="$SKYRIM_HOME/config/prefs-defaults-done"
if [ -f "$pmarker" ]; then skip "SkyrimPrefs.ini: already applied once ($(cat "$pmarker"))"
elif [ -f "$prefs" ]; then echo "own SkyrimPrefs.ini" > "$pmarker"; skip "SkyrimPrefs.ini exists — left alone"
elif [ -f "$GAMEDIR/Skyrim/SkyrimPrefs.ini" ]; then
  sed 's/^bBorderless=0/bBorderless=1/' "$GAMEDIR/Skyrim/SkyrimPrefs.ini" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs" \
    || fail "could not write SkyrimPrefs.ini"
  date '+%F' > "$pmarker"; ok "SkyrimPrefs.ini written (game defaults, borderless window)"
else skip "SkyrimPrefs.ini: Skyrim not installed yet"
fi

step "Steam login + Skyrim Special Edition"
if grep -q '"StateFlags"[[:space:]]*"4"' "$STEAM_DIR/steamapps/appmanifest_$SKYRIM_APPID.acf" 2>/dev/null; then skip "Skyrim installed"
elif grep -q 'Logged On' "$STEAM_DIR/logs/connection_log.txt" 2>/dev/null; then todo "install Skyrim: in the launcher click “Install Skyrim” (≈25 GB with Anniversary Edition)"
else todo "log in to Steam once: in the launcher click “Log in to Steam”, then “Install Skyrim”"
fi
echo "DONE"
