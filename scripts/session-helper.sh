#!/bin/bash
# Per-session helper started by the launcher (never installed anywhere; exits when the session ends).
# Ends the session (scripts/session-end.sh) when:
#   * Skyrim ran and has exited (whatever closed it: in-game quit, Dock, crash), or
#   * Skyrim never started, no launch or tool is running and the launcher is gone (e.g. only Steam was opened).
# "Skyrim" is SkyrimSE.exe itself. skse64_loader.exe and SkyrimSELauncher.exe start it and then exit, so while only a
# loader has been seen the helper waits up to LOADER_GRACE seconds for the game instead of tearing down.
# Independent of the launcher: survives the launcher being quit or force-quit. One helper at a time.
#   session-helper.sh --spawn   start a helper in the background unless one is already running (returns at once)
. "$(dirname "$0")/_env.sh"
RUN="$SKYRIM_HOME/run"; mkdir -p "$RUN" "$SKYRIM_HOME/logs"; LOG="$SKYRIM_HOME/logs/session.log"
LOADER_GRACE=${SKYRIMMT_LOADER_GRACE:-30}
log() { echo "$(date '+%F %T') helper[$$]: $*" >> "$LOG"; }
alive() { local p; p=$(cat "$1" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
if [ "${1:-}" = --spawn ]; then
  alive "$RUN/helper.pid" && exit 0
  nohup /bin/bash "$0" --run </dev/null >/dev/null 2>&1 &
  exit 0
fi
[ "${1:-}" = --run ] || { echo "usage: $0 --spawn"; exit 2; }
alive "$RUN/helper.pid" && exit 0
echo $$ > "$RUN/helper.pid"; trap 'rm -f "$RUN/helper.pid"' EXIT
log "started"
reset() { seen=0; loader=0; quiet=0; gone=0; started=$(date +%s); }
reset
end_session() {   # $1 = reason. Afterwards keep watching if a new launch already started (quit + Play right away)
  log "$1: ending session"; "$(dirname "$0")/session-end.sh"
  for _ in $(seq 5); do
    if alive "$RUN/launch-pending" || game_running || loader_running; then log "new launch in progress: watching it"; reset; return; fi
    sleep 1
  done
  exit 0
}
while :; do
  sleep 1
  if game_running; then seen=1; loader=0; quiet=0; gone=0; continue; fi
  if loader_running; then loader=1; quiet=0; gone=0; continue; fi      # Bethesda launcher / SKSE loader still open
  if keizaal_running; then   # Keizaal Online's launcher stays open around its games (as on Windows): keep the session
    if [ $seen = 1 ]; then mkdir -p "$SKYRIM_HOME/config/modkit"; date -u +%Y-%m-%dT%H:%M:%SZ >> "$SKYRIM_HOME/config/modkit/game-exits.tsv"; fi
    seen=0; loader=0; quiet=0; gone=0; continue
  fi
  if alive "$RUN/launch-pending"; then quiet=0; gone=0; continue; fi    # a launch script is starting Steam/Skyrim
  if alive "$RUN/tool-pending"; then quiet=0; gone=0; continue; fi      # a modding tool (Mod Manager → Tools) is running
  if ! server_up; then
    # nothing of ours runs (Steam not started yet, or the session already ended): give a just-requested Steam
    # start a moment to appear, then sweep leftovers and stop
    [ $(( $(date +%s) - started )) -lt 20 ] && [ $seen = 0 ] && continue
    "$(dirname "$0")/wine-sweep.sh" >> "$LOG" 2>&1; log "no wineserver: done"; exit 0
  fi
  quiet=$((quiet + 1))
  if [ $seen = 1 ]; then
    [ $quiet -ge 3 ] || continue                                        # Skyrim gone for 3 s (not a restart)
    # play time for the Mod Manager's crash fix (ModKit CrashFix.swift reads it; ISO 8601 UTC like launches.tsv)
    mkdir -p "$SKYRIM_HOME/config/modkit"; date -u -v-3S +%Y-%m-%dT%H:%M:%SZ >> "$SKYRIM_HOME/config/modkit/game-exits.tsv"
    end_session "Skyrim exited"; continue
  fi
  if [ $loader = 1 ]; then
    [ $quiet -ge "$LOADER_GRACE" ] || continue                          # loader exited: wait for SkyrimSE.exe
    end_session "loader exited but Skyrim did not start within ${LOADER_GRACE}s"; continue
  fi
  if alive "$RUN/launcher.pid"; then gone=0; continue; fi
  gone=$((gone + 1))
  [ $gone -ge 10 ] || continue                                          # launcher closed for 10 s, no game, no launch
  end_session "launcher closed without Skyrim running"
done
