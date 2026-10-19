#!/bin/bash
# Proton-compatible shim for the Wabbajack engine (jackify-engine, tools/wabbajack): the engine calls
# "<shim> run <tool.exe> args…" with its own WINEPREFIX (a separate prefix under $SKYRIM_HOME/wabbajack — never
# Skyrim's, so a running game is not touched). We run the tool with SkyrimMT's Wine runtime.
[ "${1:-}" = run ] && shift
WINE="${SKYRIMMT_WINE:?SKYRIMMT_WINE not set}"
export WINEDEBUG="${WINEDEBUG:--all}"
exec "$WINE" "$@"
