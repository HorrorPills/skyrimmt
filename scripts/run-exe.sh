#!/bin/bash
# Run a Windows program in SkyrimMT's Wine prefix (same runtime and environment as the game):
#   scripts/run-exe.sh [--wait] <file.exe> [args…]     output goes to logs/run-exe.log
# --wait: return when the program exits (Mod Manager tools: their output is captured into the Overwrite mod).
. "$(dirname "$0")/_env.sh"
wait=0; [ "${1:-}" = --wait ] && { wait=1; shift; }
exe=${1:?usage: run-exe.sh [--wait] <file.exe> [args…]}; shift
[ -f "$exe" ] || { echo "not found: $exe"; exit 1; }
mkdir -p "$SKYRIM_HOME/logs"
server_up || record_session_sync   # join a running session with its sync mode
follow_session_sync
cd "$(dirname "$exe")" || exit 1
echo "== $(date '+%F %T') $exe $*" >> "$SKYRIM_HOME/logs/run-exe.log"
if [ $wait = 1 ]; then
  RUN="$SKYRIM_HOME/run"; mkdir -p "$RUN"
  echo $$ > "$RUN/tool-pending"; trap 'rm -f "$RUN/tool-pending"' EXIT   # session-helper.sh keeps the session alive
  "$WINE" "$exe" "$@" >>"$SKYRIM_HOME/logs/run-exe.log" 2>&1; rc=$?
  echo "$(basename "$exe") exited ($rc)"; exit $rc
fi
"$WINE" "$exe" "$@" >>"$SKYRIM_HOME/logs/run-exe.log" 2>&1 &
disown
echo "started $(basename "$exe")"
