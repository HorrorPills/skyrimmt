#!/bin/bash
# Close tf2mt's Steam session (same Steam account as ours) through tf2mt's OWN teardown, never by killing it here
# (PLAN §4.2, §2.7). Refuses while Team Fortress 2 is running.
. "$(dirname "$0")/_env.sh"
[ -n "$(other_steam_pids)" ] || { echo "tf2mt's Steam is not running"; exit 0; }
TF2H="${TF2_HOME:-$HOME/Games/tf2}"
pgrep -fl 'tf_win64\.exe' | awk '$2 ~ /^C:/' | grep -q . && { echo "Team Fortress 2 is running — quit it first"; exit 1; }
for s in "/Applications/tf2mt.app/Contents/Resources/tf2mt/scripts/session-end.sh" "$HOME/Code/tf2mt/scripts/session-end.sh"; do
  [ -f "$s" ] || continue
  env -i HOME="$HOME" USER="${USER:-}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TF2_HOME="$TF2H" /bin/bash "$s"
  for _ in $(seq 30); do [ -n "$(other_steam_pids)" ] || { echo "tf2mt's Steam closed"; exit 0; }; sleep 1; done
  echo "tf2mt's Steam is still running"; exit 1
done
echo "tf2mt's session-end.sh not found — quit Steam from tf2mt"; exit 1
