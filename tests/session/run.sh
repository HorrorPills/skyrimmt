#!/bin/bash
# server_up / server_pids (scripts/_env.sh) must recognise this game folder's wineserver however the folder is spelled, and
# never another runtime's. Wine starts the server by its resolved path, so these paths once made a running server look gone
# and the session helper killed Steam as an orphan 20 s in (issue #18). No Wine needed: a copy of sleep plays the server.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/skyrimmt-session.XXXXXX"); T=$(cd "$T" && pwd -P)
pass=0; fail=0; pids=()
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL $1 (got $2, expected $3)"; fi; }
# in a subshell: _env.sh exports paths for the folder it is given
up()  { ( export SKYRIM_HOME=$1; unset GAMEDIR; . "$ROOT/scripts/_env.sh"; server_up && echo up || echo down ); }
who() { ( export SKYRIM_HOME=$1; unset GAMEDIR; . "$ROOT/scripts/_env.sh"; server_pids ); }
start() {   # $1 = real game folder, $2 = path to start the fake server by (default: as Wine does, the resolved one)
  "${2:-$1/wine/lib/wine/../../bin/wineserver}" 600 & pids+=($!); LAST=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do lsof -t "$1/wine/bin/wineserver" 2>/dev/null | grep -qx "$LAST" && return; sleep 0.2; done
}
stop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
mk() { mkdir -p "$1/wine/bin" "$1/wine/lib/wine"; cp /bin/sleep "$1/wine/bin/wineserver"; codesign -f -s - "$1/wine/bin/wineserver" 2>/dev/null; }

echo "== wineserver detection"
for name in "plain/skyrim" "Game (SSD)+[1]/skyrim" "with space/sky rim"; do
  mk "$T/$name"
  check "$name: nothing running" "$(up "$T/$name")" down
  start "$T/$name"
  check "$name: server found" "$(up "$T/$name")" up
  check "$name: the right pid" "$(who "$T/$name")" "$LAST"
  stop "$LAST"
  check "$name: gone after it stops" "$(up "$T/$name")" down
done

# a symlink anywhere in the path
mk "$T/real/skyrim"; ln -s "$T/real" "$T/link"
start "$T/real/skyrim"
check "symlinked folder: server found" "$(up "$T/link/skyrim")" up
stop "$LAST"
check "symlinked folder: gone after it stops" "$(up "$T/link/skyrim")" down

# another letter case: an existing ~/games while the launcher says ~/Games (case-insensitive volumes only)
mk "$T/games/skyrim"
if [ -x "$T/Games/skyrim/wine/bin/wineserver" ]; then
  start "$T/games/skyrim"
  check "other letter case: server found" "$(up "$T/Games/skyrim")" up
  stop "$LAST"
fi

# another runtime's server (tf2mt, a second game folder) is never ours, even with a similar name
mk "$T/mine"; mk "$T/mine-other"; mk "$T/other"
start "$T/other"; A=$LAST
start "$T/mine-other"; B=$LAST
check "other runtimes' servers don't count" "$(up "$T/mine")" down
start "$T/mine"
check "ours found among them" "$(who "$T/mine")" "$LAST"
stop "$LAST"; stop "$A"; stop "$B"

# a process with non-UTF-8 bytes in its command line, anywhere on the Mac, must not hide the server in a UTF-8 locale
mk "$T/bytes"; /usr/bin/perl -e 'exec {"/bin/sleep"} "bad\xffname", "600"' & BAD=$!; pids+=($BAD); sleep 0.3
start "$T/bytes"
check "UTF-8 locale, odd process: server found" "$(LANG=en_US.UTF-8 LC_ALL= up "$T/bytes")" up
stop "$LAST"; stop "$BAD"

# something merely reading the file isn't a server
mk "$T/reader"; tail -f "$T/reader/wine/bin/wineserver" >/dev/null 2>&1 & R=$!; pids+=($R)
check "a process reading the file isn't the server" "$(up "$T/reader")" down
stop "$R"

echo "== orphan sweep"
sweep() { ( export SKYRIM_HOME=$1; unset GAMEDIR; "$ROOT/scripts/wine-sweep.sh" >/dev/null ); }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
ntdll() { mkdir -p "$1/wine/lib/wine/x86_64-unix"; : > "$1/wine/lib/wine/x86_64-unix/ntdll.so"; echo "$1/wine/lib/wine/x86_64-unix/ntdll.so"; }
# "maps ntdll.so" is what makes a process ours: tail holding the file open plays a Wine process
mk "$T/sweep"; N=$(ntdll "$T/sweep")
tail -f "$N" >/dev/null 2>&1 & W=$!; pids+=($W); sleep 0.5
sweep "$T/sweep"
check "no server, just started: spared (its server is coming up)" "$(alive "$W")" alive
sleep 6
sweep "$T/sweep"; sleep 0.3
check "no server, older: killed as an orphan" "$(alive "$W")" gone
wait "$W" 2>/dev/null

tail -f "$N" >/dev/null 2>&1 & W=$!; pids+=($W); sleep 7
start "$T/sweep"
sweep "$T/sweep"; sleep 0.3
check "older than the running server: killed" "$(alive "$W")" gone
check "the server itself stays" "$(alive "$LAST")" alive
wait "$W" 2>/dev/null
tail -f "$N" >/dev/null 2>&1 & W=$!; pids+=($W); sleep 0.5
sweep "$T/sweep"
check "younger than the running server: stays" "$(alive "$W")" alive
stop "$W"; stop "$LAST"

# never another runtime's processes
mk "$T/theirs"; N2=$(ntdll "$T/theirs")
tail -f "$N2" >/dev/null 2>&1 & W=$!; pids+=($W); sleep 6
sweep "$T/sweep"
check "another runtime's process is never touched" "$(alive "$W")" alive
stop "$W"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
