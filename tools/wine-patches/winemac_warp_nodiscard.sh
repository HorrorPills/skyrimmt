#!/bin/bash
# Binary patch for the runtime's winemac.so (Sikarugir Wine 10.0, x86_64): stop discarding mouse motion on cursor
# warps. Uses only tools that ship with macOS (no Python / developer tools needed).
#
# Wine's -[WineApplicationController setCursorPosition:] (dlls/winemac.drv/cocoa_app.m) discards all queued
# mouse-move events and ignores every event timestamped before the warp. Games that recentre the cursor every frame
# lose most mouse motion (tf2mt measured TF2's camera updating ~40x/s at 120 fps; tf2mt docs/mouse-input.md).
# Copied from tf2mt; same Wine build. Applied on the user's machine only — the shipped runtime stays original.
# Patch (verified against original bytes first):
#   0x8399  movsd %xmm0,0x128(%r15)   (lastSetCursorPositionTime = uptime)  -> 9-byte NOP
#   0x848b  movl  $0x1800,%edx        (discard mask MOUSE_MOVED_*)          -> movl $0,%edx
# Usage: winemac_warp_nodiscard.sh apply|revert|status
set -u
SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
SO="$SKYRIM_HOME/wine/lib/wine/x86_64-unix/winemac.so"
BACKUP="$SKYRIM_HOME/backups/winemac.so.orig"
# offset original patched
PATCHES=("33689 f2410f118728010000 0f1f80000000006690"   # 0x8399
         "33931 ba00180000 ba00000000")                   # 0x848b

[ -f "$SO" ] || { echo "unknown (no winemac.so at $SO)"; exit 1; }

bytes_at() { /usr/bin/xxd -p -s "$2" -l "$3" "$1" | tr -d '\n'; }
state() {   # original | patched | unknown
  local o=1 p=1 off orig new
  for e in "${PATCHES[@]}"; do
    read -r off orig new <<< "$e"
    cur=$(bytes_at "$1" "$off" $(( ${#orig} / 2 )))
    [ "$cur" = "$orig" ] || o=0
    [ "$cur" = "$new" ] || p=0
  done
  [ $o = 1 ] && echo original || { [ $p = 1 ] && echo patched || echo unknown; }
}
install() {   # $1 = file with the new contents; ad-hoc signed, swapped in atomically
  chmod 755 "$1"
  /usr/bin/codesign -f -s - "$1" >/dev/null 2>&1 || { rm -f "$1"; echo "codesign failed"; exit 1; }
  mv -f "$1" "$SO"   # running processes keep the old inode
}

st=$(state "$SO")
case "${1:-status}" in
  status)
    echo "$st $(/usr/bin/shasum -a 256 "$SO" | cut -c1-16)" ;;
  apply)
    [ "$st" = patched ] && { echo "already patched"; exit 0; }
    [ "$st" = original ] || { echo "unexpected winemac.so contents (different Wine build?) — not patching"; exit 1; }
    [ -f "$BACKUP" ] || { mkdir -p "$(dirname "$BACKUP")"; cp -p "$SO" "$BACKUP"; }
    tmp="$SO.new"; cp "$SO" "$tmp"
    for e in "${PATCHES[@]}"; do
      read -r off orig new <<< "$e"
      echo -n "$new" | /usr/bin/xxd -r -p | dd of="$tmp" bs=1 seek="$off" conv=notrunc 2>/dev/null
    done
    [ "$(state "$tmp")" = patched ] || { rm -f "$tmp"; echo "patch verification failed"; exit 1; }
    install "$tmp"; echo "patched (backup: $BACKUP)" ;;
  revert)
    [ -f "$BACKUP" ] || { echo "no backup at $BACKUP"; exit 1; }
    cp "$BACKUP" "$SO.new"; install "$SO.new"; echo "reverted to original" ;;
  *) echo "usage: $0 apply|revert|status"; exit 2 ;;
esac
