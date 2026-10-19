#!/bin/bash
# Binary patch for the runtime's winecoreaudio.so (x86_64, Wine 10.0 / tf2mt runtime 0.6.11): Wine's audio mixes at
# a fixed rate (96 kHz by default) instead of the output device's own rate. Uses only tools that ship with macOS.
#
# Why: games mix at the rate Wine reports for the device. At 44.1 kHz (common for USB interfaces and older Macs) Skyrim's
# audio crackles under Wine; mixing at 96 kHz fixes it — the same "audio sample rate" setting CrossOver exposes in its
# Wine settings. macOS's output unit converts to the device's real rate, so the interface itself is not changed.
# Source (dlls/winecoreaudio.drv/coreaudio.c, unix_get_mix_format): params->fmt->Format.nSamplesPerSec = rate;
# Code (file 0x2071): cvttsd2si rax,[rbp-0x58] ; mov rcx,[rbx+0x10] ; mov [rcx+0x4],eax
# Patch: the conversion becomes mov eax,<rate> + nop (f2 48 0f 2c 45 a8 → b8 <imm32> 90). Same length.
# Usage: coreaudio_rate.sh apply [rate]|revert|status       status: original | patched-<rate> | unknown
set -u
SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
FILE="$SKYRIM_HOME/wine/lib/wine/x86_64-unix/winecoreaudio.so"
BACKUP="$SKYRIM_HOME/backups/winecoreaudio.so.orig"
OFF=8305                      # 0x2071
ORIG=f2480f2c45a8488b4b10
TAIL=488b4b10                 # the following instruction, part of the match

bytes_at() { /usr/bin/xxd -p -s "$OFF" -l 10 "$FILE" | tr -d '\n'; }
le32() { printf '%08x' "$1" | sed -E 's/(..)(..)(..)(..)/\4\3\2\1/'; }
state() {
  [ -f "$FILE" ] || { echo unknown; return; }
  local b; b=$(bytes_at)
  if [ "$b" = "$ORIG" ]; then echo original
  elif [ "${b:0:2}" = b8 ] && [ "${b:10:2}" = 90 ] && [ "${b:12}" = "$TAIL" ]; then
    local h=${b:2:8}; echo "patched-$((16#${h:6:2}${h:4:2}${h:2:2}${h:0:2}))"
  else echo unknown; fi
}
# patched in a copy, ad-hoc signed (macOS checks the signature of code it loads), swapped in atomically: a running
# game keeps the old file
write_hex() {
  local tmp="$FILE.new.$$"
  cp "$FILE" "$tmp" && printf '%s' "$1" | /usr/bin/xxd -r -p | /bin/dd of="$tmp" bs=1 seek="$OFF" conv=notrunc status=none \
    && /usr/bin/codesign -f -s - "$tmp" >/dev/null 2>&1 && mv -f "$tmp" "$FILE" || { rm -f "$tmp"; echo "FAIL write/codesign"; exit 1; }
}

st=$(state)
case "${1:-status}" in
  status) echo "$st" ;;
  apply)
    rate=${2:-96000}
    case $rate in 44100|48000|88200|96000|176400|192000) ;; *) echo "FAIL unsupported rate $rate"; exit 1 ;; esac
    [ "$st" = "patched-$rate" ] && { echo "already patched ($rate)"; exit 0; }
    [ "$st" = original ] || [ "${st#patched-}" != "$st" ] || { echo "FAIL $FILE: unexpected bytes (different Wine build?) — not patched"; exit 1; }
    mkdir -p "$(dirname "$BACKUP")"; [ -f "$BACKUP" ] || { [ "$st" = original ] && cp "$FILE" "$BACKUP"; }
    write_hex "b8$(le32 "$rate")90"
    [ "$(state)" = "patched-$rate" ] && echo "OK patched ($rate Hz)" || { echo "FAIL verify"; exit 1; } ;;
  revert)
    [ "$st" = original ] && { echo "OK reverted"; exit 0; }
    # only this patch's bytes (coreaudio_period.sh patches the same file)
    [ "${st#patched-}" != "$st" ] && write_hex "${ORIG:0:12}"
    [ "$(state)" = original ] && echo "OK reverted" || { echo "FAIL verify"; exit 1; } ;;
  *) echo "usage: $0 apply [rate]|revert|status"; exit 2 ;;
esac
