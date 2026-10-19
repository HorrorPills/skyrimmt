#!/bin/bash
# Binary patch for the runtime's winecoreaudio.so (x86_64, Wine 10.0 / tf2mt runtime 0.6.11): Wine reports a 30 ms
# default device period instead of 10 ms. Uses only tools that ship with macOS.
#
# Why (measured with tools/audiotap, 2026-10-19): Microsoft's XAudio2 writes exactly one period per event. With 10 ms
# periods only ~10-20 ms is ever queued, macOS pulls 11.6 ms per callback, and every late wake-up of the game's audio
# thread leaves Wine padding the output with silence: ~13 gaps per second, heard as crackle even in the main menu.
# Underruns in 25 s of a test tone: 10 ms 331 (idle) / 353 (all cores busy); 20 ms 3 / 5; 30 ms 0 / 0 (with the
# 96 kHz mix rate, coreaudio_rate.sh). Cost: ~20 ms more audio latency (sound only; input is unaffected).
# Source (dlls/winecoreaudio.drv/coreaudio.c): static const REFERENCE_TIME def_period = 100000;
# Code: get_device_period (file 0x25cd) and its 32-bit thunk (0x2fdf): movq $0x186a0,(reg) → movq $0x493e0,(reg)
# Usage: coreaudio_period.sh apply|revert|status
set -u
SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
FILE="$SKYRIM_HOME/wine/lib/wine/x86_64-unix/winecoreaudio.so"
SITES=("9677 48c700a0860100 48c700e0930400" "12255 48c701a0860100 48c701e0930400")   # offset, original, patched

bytes_at() { /usr/bin/xxd -p -s "$1" -l 7 "$FILE" | tr -d '\n'; }
state() {
  [ -f "$FILE" ] || { echo unknown; return; }
  local o=1 p=1 off orig new cur
  for e in "${SITES[@]}"; do
    read -r off orig new <<< "$e"; cur=$(bytes_at "$off")
    [ "$cur" = "$orig" ] || o=0; [ "$cur" = "$new" ] || p=0
  done
  [ $o = 1 ] && echo original || { [ $p = 1 ] && echo patched || echo unknown; }
}
# both sites in a copy, ad-hoc signed, swapped in atomically (a running game keeps the old file)
write_sites() {   # $1 = 2 (patched) or 1 (original): which column to write
  local tmp="$FILE.new.$$" off orig new
  cp "$FILE" "$tmp" || exit 1
  for e in "${SITES[@]}"; do
    read -r off orig new <<< "$e"
    [ "$1" = 2 ] && b=$new || b=$orig
    printf '%s' "$b" | /usr/bin/xxd -r -p | /bin/dd of="$tmp" bs=1 seek="$off" conv=notrunc status=none || { rm -f "$tmp"; exit 1; }
  done
  /usr/bin/codesign -f -s - "$tmp" >/dev/null 2>&1 && mv -f "$tmp" "$FILE" || { rm -f "$tmp"; echo "FAIL codesign"; exit 1; }
}

st=$(state)
case "${1:-status}" in
  status) echo "$st" ;;
  apply)
    [ "$st" = patched ] && { echo "already patched"; exit 0; }
    [ "$st" = original ] || { echo "FAIL $FILE: unexpected bytes (different Wine build?) — not patched"; exit 1; }
    write_sites 2; [ "$(state)" = patched ] && echo "OK patched (30 ms)" || { echo "FAIL verify"; exit 1; } ;;
  revert)
    [ "$st" = original ] && { echo "OK reverted"; exit 0; }
    [ "$st" = patched ] || { echo "FAIL unexpected bytes"; exit 1; }
    write_sites 1; [ "$(state)" = original ] && echo "OK reverted" || { echo "FAIL verify"; exit 1; } ;;
  *) echo "usage: $0 apply|revert|status"; exit 2 ;;
esac
