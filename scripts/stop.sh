#!/bin/bash
# Hard stop of SkyrimMT's Wine session (this prefix only). Normal teardown is session-end.sh.
. "$(dirname "$0")/_env.sh"; "$WINESERVER" -k 2>/dev/null; "$SKYRIMMT_ROOT/scripts/wine-sweep.sh"; rm -f "$SESSION_SYNC"; echo "wine stopped"
