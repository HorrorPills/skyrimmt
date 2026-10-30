#!/bin/bash
# One-click launch (launcher Play): Steam if needed (waits for login; not for the GOG version), then Skyrim
# (scripts/skyrim.sh).
. "$(dirname "$0")/_env.sh"
notify() { osascript -e "display notification \"$1\" with title \"Skyrim\"" >/dev/null 2>&1; }
if game_running; then notify "Skyrim is already running."; exit 0; fi
RUN="$SKYRIM_HOME/run"; mkdir -p "$RUN"
# a session that is still shutting down (quit + Play right away) must finish first, or it would close our Steam
for _ in $(seq 45); do p=$(cat "$RUN/teardown.lock/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null || break; sleep 1; done
# the mod manager may be deploying: wait for it (PLAN §6)
for _ in $(seq 120); do [ -d "$RUN/deploy.lock" ] || break; sleep 1; done
echo $$ > "$RUN/launch-pending"; trap 'rm -f "$RUN/launch-pending"' EXIT   # tells session-helper.sh a launch is in progress
if [ -n "$(other_steam_pids)" ]; then
  notify "tf2mt's Steam is running with the same account — close it first."; echo "tf2mt's Steam is running"; exit 1
fi
if ! is_gog && ! steam_running; then notify "Starting Steam…"; fi
"$SKYRIMMT_ROOT/scripts/skyrim.sh" "$@" || { notify "Skyrim did not start — see $SKYRIM_HOME/logs/skyrim.log"; exit 1; }
