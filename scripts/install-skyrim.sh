#!/bin/bash
# Ask the running Steam client to install Skyrim Special Edition (opens Steam's install dialog).
. "$(dirname "$0")/_env.sh"
steam_running || { echo "Start Steam first."; exit 1; }
follow_session_sync
(cd "$STEAM_DIR" && "$WINE" steam.exe "steam://install/$SKYRIM_APPID" >/dev/null 2>&1)
echo "Steam is installing Skyrim Special Edition — follow the Steam window (≈16 GB)."
