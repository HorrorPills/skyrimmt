#!/bin/bash
# Kill orphaned Wine processes of THIS SkyrimMT runtime: processes that map our ntdll.so but whose wineserver is gone
# (or that are older than the running wineserver, i.e. left over from a server that died). SkyrimMT has its own
# runtime copy (an APFS clone is a separate file), so tf2mt's processes and other Wine installs (CrossOver, Whisky,
# …) map a different ntdll.so and are never touched. Prints what it killed.
. "$(dirname "$0")/_env.sh"
# NTDLL (our runtime's ntdll.so) comes from _env.sh
[ -f "$NTDLL" ] || exit 0
secs() { awk -F'[-:]' '{ if (NF==4) print $1*86400+$2*3600+$3*60+$4; else if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }' <<<"$1"; }
server=$(pgrep -f "$SKYRIM_HOME/wine/.*wineserver" | head -1)
server_age=-1; [ -n "$server" ] && server_age=$(secs "$(ps -o etime= -p "$server" | tr -d ' ')")
for pid in $(lsof -t "$NTDLL" 2>/dev/null | sort -u); do
  [ "$pid" = "$server" ] && continue
  if [ "$server_age" -lt 0 ]; then why="no wineserver"
  else
    age=$(secs "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"); [ -z "$age" ] && continue
    [ "$age" -gt $((server_age + 5)) ] || continue
    why="older than the running wineserver"
  fi
  echo "sweep: killing $pid ($(ps -o command= -p "$pid" | cut -c1-80)) — $why"
  kill -9 "$pid" 2>/dev/null
done
exit 0
