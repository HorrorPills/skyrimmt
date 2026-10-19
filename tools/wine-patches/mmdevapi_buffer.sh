#!/bin/bash
# Binary patch for the runtime's mmdevapi.dll (x86_64, Wine 10.0 / tf2mt runtime 0.6.11): the smallest shared-mode audio
# buffer becomes 9 periods (90 ms) instead of Wine's 3 (30 ms). Uses only tools that ship with macOS.
#
# Why: with Microsoft's XAudio2 (needed for Skyrim's sound distances, scripts/_env.sh ensure_audio_libs) the game asks
# for a 20 ms buffer; Wine rounds it to 3 × its 10 ms period. Under the game's CPU load (Rosetta + renderer) a late
# period drains that, CoreAudio plays silence for the gap → crackle. Windows copes with 20 ms thanks to real-time audio
# threads; here a deeper buffer does it (tools/audioprobe measures the queued audio).
# Source (dlls/mmdevapi/client.c, adjust_timing, shared mode): if (*duration < 3 * *period) *duration = 3 * *period;
# Code (file 0x13a9c): lea rax,[rax+2*rax] ; cmp rax,[rsp+0x1a0] ; cmovl rax,[rsp+0x1a0]
# Patch: the lea's SIB scale 2 → 8, i.e. 48 8d 04 40 → 48 8d 04 c0 (rax+8*rax = 9 × period). Same length.
# Applied to the builtin (lib/wine/x86_64-windows) and the prefix's system32 copy.
# Usage: mmdevapi_buffer.sh apply|revert|status
set -u
SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
FILES=("$SKYRIM_HOME/wine/lib/wine/x86_64-windows/mmdevapi.dll" "$SKYRIM_HOME/prefix/drive_c/windows/system32/mmdevapi.dll")
BACKUP="$SKYRIM_HOME/backups/mmdevapi.dll.orig"
OFF=80540                     # 0x13a9c
ORIG=488d0440483b8424a0010000
NEW=488d04c0483b8424a0010000

bytes_at() { /usr/bin/xxd -p -s "$OFF" -l 12 "$1" | tr -d '\n'; }
state() { local b; b=$(bytes_at "$1"); [ "$b" = "$ORIG" ] && echo original || { [ "$b" = "$NEW" ] && echo patched || echo unknown; }; }
overall() {
  local s first=""; for f in "${FILES[@]}"; do [ -f "$f" ] || { echo unknown; return; }; s=$(state "$f"); [ -z "$first" ] && first=$s; [ "$s" = "$first" ] || { echo mixed; return; }; done; echo "$first"
}
write_at() { printf '%s' "$2" | /usr/bin/xxd -r -p | /bin/dd of="$1" bs=1 seek="$OFF" conv=notrunc status=none; }

st=$(overall)
case "${1:-status}" in
  status) echo "$st" ;;
  apply)
    [ "$st" = patched ] && { echo "already patched"; exit 0; }
    for f in "${FILES[@]}"; do s=$(state "$f"); [ "$s" = original ] || [ "$s" = patched ] || { echo "FAIL $f: unexpected bytes (different Wine build?) — not patched"; exit 1; }; done
    mkdir -p "$(dirname "$BACKUP")"; [ -f "$BACKUP" ] || cp "${FILES[0]}" "$BACKUP"
    for f in "${FILES[@]}"; do [ "$(state "$f")" = original ] && write_at "$f" "$NEW"; done
    [ "$(overall)" = patched ] && echo "OK patched" || { echo "FAIL verify"; exit 1; } ;;
  revert)
    for f in "${FILES[@]}"; do [ "$(state "$f")" = patched ] && write_at "$f" "$ORIG"; done
    [ "$(overall)" = original ] && echo "OK reverted" || { echo "FAIL verify"; exit 1; } ;;
  *) echo "usage: $0 apply|revert|status"; exit 2 ;;
esac
