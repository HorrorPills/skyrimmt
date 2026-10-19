#!/bin/bash
# End the SkyrimMT session cleanly: Steam shut down, wineserver stopped, orphans swept. Only ever touches THIS
# prefix's wineserver (WINESERVER -k uses our WINEPREFIX) and THIS runtime's processes (wine-sweep.sh).
# Idempotent and locked: safe to run from several places.
. "$(dirname "$0")/_env.sh"
RUN="$SKYRIM_HOME/run"; mkdir -p "$RUN" "$SKYRIM_HOME/logs"; LOG="$SKYRIM_HOME/logs/session.log"
log() { echo "$(date '+%F %T') end[$$]: $*" >> "$LOG"; }
LOCK="$RUN/teardown.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  other=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then log "teardown already running ($other)"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
fi
echo $$ > "$LOCK/pid"; trap 'rm -rf "$LOCK"' EXIT
if game_running || loader_running; then log "Skyrim is running: nothing to do"; exit 0; fi
log "start (steam running: $(steam_running && echo yes || echo no))"
if steam_running; then
  (cd "$STEAM_DIR" && "$WINE" steam.exe -shutdown >/dev/null 2>&1) &
  for _ in $(seq 30); do server_up || break; sleep 1; done
fi
if server_up; then log "wineserver still up: wineserver -k"; "$WINESERVER" -k 2>/dev/null; for _ in $(seq 10); do server_up || break; sleep 1; done; fi
"$(dirname "$0")/wine-sweep.sh" >> "$LOG" 2>&1
log "done (wineserver: $(server_up && echo STILL UP || echo gone))"
