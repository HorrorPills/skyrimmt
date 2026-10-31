#!/bin/bash
# Start the Steam client inside SkyrimMT's Wine prefix (required before launching Skyrim)
#   scripts/steam.sh            background (no window) — normal use
#   scripts/steam.sh --login    with window — first login / account changes
#   scripts/steam.sh --show     open the running client's main window (launcher "Show Steam")
. "$(dirname "$0")/_env.sh"
is_gog && { echo "not needed: this is a GOG game environment"; exit 1; }
cd "$STEAM_DIR" || { echo "Steam is not installed — run scripts/setup.sh"; exit 1; }
mkdir -p "$SKYRIM_HOME/logs"
if [ "${1:-}" = --show ]; then
  steam_running || { echo "steam is not running"; exit 1; }
  follow_session_sync; "$WINE" steam.exe steam://open/main >/dev/null 2>&1; exit 0
fi
steam_running && { echo "steam already running"; exit 0; }
# leftovers of a crashed session (orphans of a dead wineserver) stop a new session from starting: sweep first
"$SKYRIMMT_ROOT/scripts/wine-sweep.sh" >> "$SKYRIM_HOME/logs/session.log" 2>&1
server_up || record_session_sync
follow_session_sync
silent=-silent; [ "${1:-}" = --login ] && silent=
"$WINE" steam.exe $silent -no-cef-sandbox >"$SKYRIM_HOME/logs/steam.log" 2>&1 &
disown
echo "steam started (log: $SKYRIM_HOME/logs/steam.log)"
