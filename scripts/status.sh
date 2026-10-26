#!/bin/bash
# One-shot state for the launcher (polled every 2 s): which of OUR processes run, Steam login state, and whether
# tf2mt's Steam is running (same Steam account → conflicts). key=value lines. One pgrep + one lsof per runtime
# (same ownership rule as win_pids in _env.sh).
. "$(dirname "$0")/_env.sh"
cands=$(LC_ALL=C pgrep -fil 'skyrimse\.exe|skse64_loader\.exe|skyrimselauncher\.exe|steam\.exe|steamwebhelper\.exe|keizaal-online\.exe' | LC_ALL=C awk '{
  pid = $1; sub(/^[0-9]+ /, ""); i = index(tolower($0), ".exe"); if (!i) next
  a0 = tolower(substr($0, 1, i + 3)); n = split(a0, p, "\\"); print pid, p[n] }')
ours=$( [ -n "$cands" ] && lsof -t "$NTDLL" 2>/dev/null | sort -u)
theirs=$( [ -n "$cands" ] && [ -f "$TF2MT_NTDLL" ] && lsof -t "$TF2MT_NTDLL" 2>/dev/null | sort -u)
pick() { echo "$cands" | awk -v names="$1" 'BEGIN { split(names, n, ","); for (i in n) w[n[i]] = 1 } ($2 in w) { print $1 }' | grep -Fx -f <(echo "${2:-none}") ; }
gp=$(pick skyrimse.exe "$ours" | tr '\n' ' ')
echo "game=$([ -n "$gp" ] && echo 1 || echo 0) game_pids=$gp"
echo "loader=$([ -n "$(pick skse64_loader.exe,skyrimselauncher.exe "$ours")" ] && echo 1 || echo 0)"
echo "steam_pids=$(pick steam.exe,steamwebhelper.exe "$ours" | tr '\n' ' ')"
steam=0; [ -n "$(pick steam.exe "$ours")" ] && steam=1
online=0
if [ $steam = 1 ]; then
  st=$(tail -400 "$STEAM_DIR/logs/connection_log.txt" 2>/dev/null | grep -oE '\[(Logged On|Logged Off|Logging On)' | tail -1)
  [ "$st" = "[Logged On" ] && online=1
fi
echo "steam=$steam online=$online"
echo "other_steam=$([ -n "$(pick steam.exe "$theirs")" ] && echo 1 || echo 0)"
echo "keizaal=$([ -n "$(pick keizaal-online.exe "$ours")" ] && echo 1 || echo 0)"   # Keizaal Online's launcher
echo "deploy_lock=$([ -d "$SKYRIM_HOME/run/deploy.lock" ] && echo 1 || echo 0)"
