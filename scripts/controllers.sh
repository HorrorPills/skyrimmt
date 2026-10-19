#!/bin/bash
# Which controllers Skyrim will see: runs xinputprobe.exe (XInput 1.3, as Skyrim SE) in Skyrim's Wine prefix.
#   controllers.sh   → "slot <n> connected <subtype>" / "slot <n> none" lines (exit 0), "error …" otherwise
. "$(dirname "$0")/_env.sh"
probe="${SKYRIMMT_XINPUTPROBE:-$SKYRIMMT_ROOT/tools/xinputprobe.exe}"
[ -f "$probe" ] || probe="$SKYRIMMT_ROOT/build/xinputprobe/xinputprobe.exe"
[ -f "$probe" ] || { echo "error probe missing"; exit 1; }
[ -x "$WINE" ] || { echo "error no wine runtime"; exit 1; }
ensure_winebus_options
"$WINE" "$probe" 2>/dev/null | tr -d '\r'
