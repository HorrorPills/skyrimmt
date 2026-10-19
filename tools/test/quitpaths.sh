#!/bin/bash
# Automated pre-check of the six session quit paths (PLAN §4.3; tf2mt docs/session-lifetime.md) against a built
# SkyrimMT.app. The owner still re-tests them by hand (M2 acceptance). Drives the launcher by clicking its buttons
# (window coordinates of the 980x722 window) and Skyrim through its console (gamekeys).
#   tools/test/quitpaths.sh [path-to-SkyrimMT.app] [paths…: 1 2 3 4 5 6]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; . "$ROOT/scripts/_env.sh"
APP=${1:-$ROOT/build/app/SkyrimMT.app}; shift || true
PATHS=${*:-1 2 3 4 5 6}
K="$ROOT/build/tools/gamekeys"
log() { echo "$(date '+%T') $*"; }
lpid() { pgrep -f "$APP/Contents/MacOS/SkyrimMT" | head -1 | grep .; }
lstart() { lpid >/dev/null && return; open -n "$APP"; for _ in $(seq 20); do GAMEKEYS_WINDOW=SkyrimMT "$K" window >/dev/null && break; sleep 0.5; done; sleep 3; }
lquit() { osascript -e 'tell application id "local.skyrimmt.launcher" to quit' >/dev/null 2>&1; for _ in $(seq 10); do lpid >/dev/null || return 0; sleep 0.5; done; }
lforce() { local p; p=$(lpid) && kill -9 "$p"; }
lclick() { for _ in 1 2 3; do GAMEKEYS_WINDOW=SkyrimMT "$K" click "$1" "$2" && return 0; sleep 2; done; log "  FAIL: could not click the launcher"; }
play() { lclick 790 568; }
startsteam() { lclick 790 632; }
st() { "$ROOT/scripts/status.sh"; }
wait_game() {   # game process AND its window (the console needs the window), then a moment for the main menu
  for _ in $(seq 180); do game_running && "$K" window >/dev/null && { sleep 12; return 0; }; sleep 1; done
  log "FAIL: game did not start"; return 1; }
gquit() { "$K" keys grave; sleep 0.5; "$K" type qqq; for _ in $(seq 30); do game_running || return 0; sleep 1; done; log "FAIL: game did not quit"; }
helper_alive() { p=$(cat "$SKYRIM_HOME/run/helper.pid" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
wait_clean() {   # session over: no wineserver, no Wine process of our runtime, helper gone
  local t0=$(date +%s)
  for _ in $(seq 120); do
    if ! server_up && [ -z "$(lsof -t "$NTDLL" 2>/dev/null)" ] && ! helper_alive; then log "  clean after $(( $(date +%s) - t0 )) s"; return 0; fi
    sleep 1
  done
  log "FAIL: not clean after 120 s: server=$(server_up && echo up) procs=$(lsof -t "$NTDLL" 2>/dev/null | wc -l | tr -d ' ') helper=$(helper_alive && echo alive)"; return 1
}
result() { if [ "$1" = 0 ]; then log "PASS $2"; else log "FAIL $2"; fi; }

for p in $PATHS; do
  case $p in
    1) log "path 1: quit game with launcher open"; lstart; play; wait_game && gquit; wait_clean; r=$?
       lpid >/dev/null || { log "  launcher died"; r=1; }; result $r "1" ;;
    2) log "path 2: quit game, then launcher"; lstart; play; wait_game && gquit; sleep 2; lquit; wait_clean; result $? "2" ;;
    3) log "path 3: quit launcher in-game, then game"; lstart; play; wait_game; lquit; sleep 8
       game_running && steam_running || log "  FAIL: game or Steam died with the launcher"
       gquit; wait_clean; result $? "3" ;;
    4) log "path 4: force-quit launcher in-game, then game"; lstart; play; wait_game; lforce; sleep 8
       game_running && steam_running || log "  FAIL: game or Steam died with the launcher"
       gquit; wait_clean; result $? "4" ;;
    5) log "path 5: Steam only, then quit launcher"; lstart; startsteam
       for _ in $(seq 120); do [ "$(st | grep -o 'online=1')" ] && break; sleep 1; done; log "  steam: $(st | grep -o 'steam=. online=.')"
       sleep 5; lquit; wait_clean; result $? "5" ;;
    6) log "path 6: quit game and press Play within 3 s"; lstart; play; wait_game; old=$(game_pids); gquit
       game_running && { log "  FAIL: first game did not quit"; result 1 "6"; continue; }
       sleep 3; play
       if wait_game && [ "$(game_pids)" != "$old" ]; then log "  relaunched OK (new pid $(game_pids))"; gquit; wait_clean; result $? "6"; else result 1 "6"; fi ;;
  esac
  lquit; sleep 2
done
