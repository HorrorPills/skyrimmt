#!/bin/bash
# Skyrim's own files: does the folder Play uses still hold them? A missing archive (e.g. a disk cleanup removing large
# files) makes every world load crash, with or without mods: no skeleton in "Skyrim - Meshes0.bsa", no player model.
#   scripts/gamefiles.sh [status]   one missing file per line (nothing: complete)
#   scripts/gamefiles.sh repair     Steam verifies and restores them; a pinned version or GOG can't, and says so
# The list: Skyrim_Default.ini's archive lists, plus what SkyrimMT recorded as the game's own (baseline.tsv).
. "$(dirname "$0")/_env.sh"
status() {
  [ -f "$GAMEDIR/SkyrimSE.exe" ] || return 0   # not installed: the "Skyrim installed" check covers that
  local base="$SKYRIM_HOME/config/modkit/baseline.tsv"
  [ "$GAMEDIR" = "$BASE_GAMEDIR" ] || base="$SKYRIM_HOME/config/modkit/versions/$(basename "$GAMEDIR")/baseline.tsv"
  {
    /usr/bin/tr -d '\r' < "$GAMEDIR/Skyrim_Default.ini" 2>/dev/null | /usr/bin/sed -n 's/^sResourceArchiveList2*=//p' | /usr/bin/tr ',' '\n' | /usr/bin/sed 's/^ *//; s/ *$//; /^$/d; /^Skyrim - Patch\.bsa$/Id; /^Skyrim - Voices_/Id; s#^#Data/#'   # (no build ships Patch; Voices is named per language)
    [ -f "$base" ] && /usr/bin/cut -f1 "$base" | /usr/bin/grep -iE '^Data/[^/]+\.(bsa|esm)$'
  } | /usr/bin/sort -fu | while IFS= read -r f; do [ -e "$GAMEDIR/$f" ] || echo "${f#Data/}"; done
}
case "${1:-status}" in
  status) status ;;
  repair)
    n=$(status | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$n" = 0 ] && { echo "Skyrim's game files are complete."; exit 0; }
    is_gog && { echo "$n game files are missing. Install from your GOG installers again (Setup tab)."; exit 1; }
    [ "$GAMEDIR" = "$BASE_GAMEDIR" ] || { echo "$n game files of Skyrim $(basename "$GAMEDIR") are missing. Remove that version in the Game tab and download it again."; exit 1; }
    game_running && { echo "Quit Skyrim first."; exit 1; }
    follow_session_sync
    (cd "$STEAM_DIR" && nohup "$WINE" steam.exe "steam://validate/$SKYRIM_APPID" >/dev/null 2>&1 &)
    echo "Steam is restoring $n missing game files. Keep it open until the download finishes." ;;
  *) echo "usage: $0 [status|repair]"; exit 2 ;;
esac
