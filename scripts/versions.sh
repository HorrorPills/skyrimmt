#!/bin/bash
# Skyrim version switcher. Steam's own install (whatever Steam updated it to) stays untouched; other versions live
# side by side in $SKYRIM_HOME/versions/<version>/ and are what Play starts when selected (config/game-version).
# A version folder starts as an APFS clone of the vanilla game files (no extra space) and is brought to the wanted
# version from Steam's own depots with DepotDownloader (SteamRE, GPL-2, separate program fetched from its GitHub
# release, run under the player's own Steam account — first login by QR code in the Steam mobile app; nothing is
# typed into SkyrimMT). Only files that differ are downloaded (-validate).
#   versions.sh status                 key=value lines
#   versions.sh download <version>     create/update versions/<version> (progress lines "PROGRESS <pct>", QR code lines)
#   versions.sh select <version|steam> which game folder Play uses (the app redeploys the profile's mods)
#   versions.sh remove <version>
. "$(dirname "$0")/_env.sh"
VDIR="$SKYRIM_HOME/versions"; DD_DIR="$SKYRIM_HOME/tools/depotdownloader"; DD="$DD_DIR/DepotDownloader"
USERFILE="$SKYRIM_HOME/config/steam-depot-user"

# Known versions: depot:manifest pairs (Steam app 489830), each from two independent guides (docs/m1-sources.md):
# 1.6.1170 (+ Wildlander wiki, 2026-10-18); 1.5.97 (Nexus article 6547 + STEP forum topic 16280, 2026-10-18).
manifests() {
  case $1 in
    1.6.1170) echo "489831:8442952117333549665 489832:8042843504692938467 489833:1914580699073641964" ;;
    1.5.97) echo "489831:7848722008564294070 489832:8702665189575304780 489833:2289561010626853674" ;;
    *) return 1 ;;
  esac
}
KNOWN="1.6.1170 1.5.97"

installed() { for d in "$VDIR"/*/; do [ -f "$d.skyrimmt-version" ] && basename "$d"; done 2>/dev/null; }

get_dd() {
  [ -x "$DD" ] && return 0
  echo "STEP Getting DepotDownloader (Steam depot downloader, GPL-2)…"
  mkdir -p "$DD_DIR" "$SKYRIM_HOME/cache"
  local json url digest zip="$SKYRIM_HOME/cache/DepotDownloader-macos-arm64.zip"
  json=$(curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/SteamRE/DepotDownloader/releases/latest) || { echo "FAIL can't reach GitHub"; return 1; }
  url=$(echo "$json" | tr ',' '\n' | grep -o '"browser_download_url": *"[^"]*macos-arm64.zip"' | sed 's/.*"\(http[^"]*\)"/\1/')
  digest=$(echo "$json" | tr ',' '\n' | grep -B30 'macos-arm64.zip' | grep -o '"digest": *"sha256:[0-9a-f]*"' | tail -1 | sed 's/.*sha256:\([0-9a-f]*\)"/\1/')
  [ -n "$url" ] || { echo "FAIL no macOS arm64 build in the latest DepotDownloader release"; return 1; }
  curl -fsSL -o "$zip" "$url" || { echo "FAIL download failed"; return 1; }
  if [ -n "$digest" ]; then echo "$digest  $zip" | shasum -a 256 -c - >/dev/null || { echo "FAIL checksum mismatch"; rm -f "$zip"; return 1; }; fi
  ditto -x -k "$zip" "$DD_DIR" && rm -f "$zip"
  [ -x "$DD" ] || chmod +x "$DD" 2>/dev/null
  xattr -dr com.apple.quarantine "$DD_DIR" 2>/dev/null
  [ -x "$DD" ] || { echo "FAIL DepotDownloader not found after unpacking"; return 1; }
}

case "${1:-status}" in
  status)
    echo "current=$(cat "$SKYRIM_HOME/config/game-version" 2>/dev/null || echo steam)"
    echo "steam_version=$(GAMEDIR="$STEAM_GAMEDIR" "$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/^game_version=//p')"
    echo "installed=$(installed | tr '\n' ' ')"
    echo "known=$KNOWN"
    echo "steam_user=$(cat "$USERFILE" 2>/dev/null)"
    ;;
  prepare) get_dd && "$DD" -V 2>&1 | head -2 ;;
  download)
    v=${2:?usage: versions.sh download <version>}
    pairs=$(manifests "$v") || { echo "FAIL unknown version $v (known: $KNOWN)"; exit 2; }
    game_running && { echo "FAIL quit Skyrim first"; exit 1; }
    get_dd || exit 1
    dst="$VDIR/$v"; mkdir -p "$dst"
    if [ ! -f "$dst/SkyrimSE.exe" ]; then
      echo "STEP Copying the game files (APFS clone, no extra space)…"
      base="$SKYRIM_HOME/config/modkit/baseline.tsv"   # vanilla file list (before SkyrimMT deployed mods)
      if [ -f "$base" ]; then
        while IFS= read -r rel; do
          [ -n "$rel" ] && [ -f "$STEAM_GAMEDIR/$rel" ] || continue
          mkdir -p "$dst/$(dirname "$rel")"; cp -c "$STEAM_GAMEDIR/$rel" "$dst/$rel" 2>/dev/null
        done < "$base"
      else
        cp -cR "$STEAM_GAMEDIR/." "$dst/"
      fi
    fi
    echo "STEP Downloading Skyrim $v from Steam (only files that differ)…"
    depots=""; mans=""
    for p in $pairs; do depots="$depots ${p%%:*}"; mans="$mans ${p#*:}"; done
    if [ -s "$USERFILE" ]; then login=(-username "$(cat "$USERFILE")" -remember-password); else login=(-qr -remember-password); fi
    cd "$DD_DIR" || exit 1
    # shellcheck disable=SC2086
    "$DD" -app "$SKYRIM_APPID" -depot $depots -manifest $mans "${login[@]}" -dir "$dst" -validate -os windows 2>&1 |
      while IFS= read -r line; do
        case $line in
          *"Next time you can login with -username "*) u=${line#*-username }; u=${u%% *}; mkdir -p "$(dirname "$USERFILE")"; echo "$u" > "$USERFILE"; echo "LOGGEDIN $u" ;;
          *"QR code"*|*"sign in with this QR"*) echo "QRSTART" ;;
          *"█"*|*"▀"*|*"▄"*) echo "QR $line" ;;
          *%*) pct=$(echo "$line" | grep -oE '^ *[0-9]+(\.[0-9]+)?%' | tr -d ' %'); [ -n "$pct" ] && echo "PROGRESS $pct" ;;
          *"Total downloaded"*|*"Download complete"*|*"Got depot key"*|*"Got manifest request code"*|*Error*|*error*|*Failed*|*failed*) echo "INFO $line" ;;
        esac
      done
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "FAIL DepotDownloader exited with $rc"; exit 1; }
    rm -rf "$dst/.DepotDownloader"
    printf '%s' "$SKYRIM_APPID" > "$dst/steam_appid.txt"   # start without the Steam relaunch (scripts/skyrim.sh)
    got=$(GAMEDIR="$dst" "$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/^game_version=//p')
    case $got in "$v"|"$v".*) ;; *) echo "FAIL the downloaded game reports version $got, not $v"; exit 1 ;; esac
    echo "$v" > "$dst/.skyrimmt-version"
    echo "DONE Skyrim $v ready"
    ;;
  select)
    v=${2:?usage: versions.sh select <version|steam>}
    game_running && { echo "quit Skyrim first"; exit 1; }
    if [ "$v" = steam ]; then rm -f "$SKYRIM_HOME/config/game-version"
    else [ -f "$VDIR/$v/.skyrimmt-version" ] || { echo "Skyrim $v is not installed"; exit 1; }; echo "$v" > "$SKYRIM_HOME/config/game-version"; fi
    echo "selected $v"
    ;;
  remove)
    v=${2:?usage: versions.sh remove <version>}
    [ "$(cat "$SKYRIM_HOME/config/game-version" 2>/dev/null)" = "$v" ] && { echo "switch to another version first"; exit 1; }
    rm -rf "${VDIR:?}/$v" "$SKYRIM_HOME/config/modkit/versions/$v"; echo "removed $v"
    ;;
  *) echo "usage: versions.sh status|download|select|remove"; exit 2 ;;
esac
