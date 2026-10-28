#!/bin/bash
# The Metal renderer (DXMT) pinned in config/release.conf, newer than the runtime's v0.80: fixes the black shadows
# that follow characters (issue #2) and the stray-Release crash itself (DXMT 66277b8), so the
# binary patch (tools/wine-patches/dxmt_purevirtual_return.sh) isn't needed with it.
#   scripts/dxmt.sh [status]   up-to-date | outdated <installed> | no-runtime
#   scripts/dxmt.sh install    download (cache/), verify, install into the runtime and the prefix, record wine/.dxmt-build
# Wine must not be running (its processes keep the old files). The DXMT it replaces is kept in backups/dxmt-<version>.
# SKYRIMMT_DXMT=<file> installs from a local archive instead of DXMT_URL (checksum still verified).
. "$(dirname "$0")/_env.sh"
. "$SKYRIMMT_ROOT/config/release.conf" 2>/dev/null || true   # DXMT_VERSION / DXMT_URL / DXMT_SHA256
MARK="$SKYRIM_HOME/wine/.dxmt-build"
LIB="$SKYRIM_HOME/wine/lib/wine"
PREFIX_DLLS="d3d11 dxgi d3d10core winemetal"   # the prefix's real copies (its nvapi64/nvngx are Wine stubs: left alone)

installed() { cat "$MARK" 2>/dev/null || /usr/bin/perl -0777 -ne 'print $1 if /DXMT D3D\0+([\x21-\x7e]{2,40})\0/' "$LIB/x86_64-windows/d3d11.dll" 2>/dev/null; }
status() {
  [ -d "$LIB" ] || { echo no-runtime; return; }
  [ -n "${DXMT_VERSION:-}" ] || { echo up-to-date; return; }   # nothing pinned: the runtime's own DXMT
  local v; v=$(installed); [ "$v" = "$DXMT_VERSION" ] && echo up-to-date || echo "outdated ${v:-unknown}"
}

case "${1:-status}" in
  status) status ;;
  install)
    st=$(status)
    [ "$st" = up-to-date ] && { echo "DXMT $(installed) already installed"; exit 0; }
    [ "$st" = no-runtime ] && { echo "no Wine runtime in $SKYRIM_HOME"; exit 1; }
    server_up && { echo "Wine is running in $SKYRIM_HOME — quit Skyrim and Steam first"; exit 1; }
    src="${SKYRIMMT_DXMT:-$DXMT_URL}"; archive="$src"
    if [[ $src == http* ]]; then
      archive="$SKYRIM_HOME/cache/$(basename "$src")"
      if ! echo "$DXMT_SHA256  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$archive.part" "$src" && mv "$archive.part" "$archive" || { echo "DXMT download failed"; exit 1; }
      fi
    fi
    echo "$DXMT_SHA256  $archive" | shasum -a 256 -c - >/dev/null 2>&1 || { echo "DXMT checksum mismatch ($archive)"; exit 1; }
    work=$(mktemp -d "$SKYRIM_HOME/cache/dxmt.XXXXXX"); trap 'rm -rf "$work"' EXIT
    tar -xzf "$archive" -C "$work" || { echo "could not unpack $archive"; exit 1; }
    new=$(dirname "$(find "$work" -path '*/x86_64-windows/d3d11.dll' | head -1)"); new=${new%/x86_64-windows}
    [ -f "$new/x86_64-unix/winemetal.so" ] && [ -f "$new/i386-windows/d3d11.dll" ] || { echo "unexpected DXMT archive layout"; exit 1; }
    old=$(installed); bk="$SKYRIM_HOME/backups/dxmt-${old:-runtime}"
    if [ ! -d "$bk" ]; then   # first replacement of that version: keep it (runtime + prefix copies)
      for arch in x86_64-windows i386-windows x86_64-unix; do
        mkdir -p "$bk/$arch"; for f in "$new/$arch"/*; do [ -f "$LIB/$arch/${f##*/}" ] && cp -p "$LIB/$arch/${f##*/}" "$bk/$arch/"; done
      done
      for sys in system32 syswow64; do
        mkdir -p "$bk/$sys"; for f in $PREFIX_DLLS; do [ -f "$WINEPREFIX/drive_c/windows/$sys/$f.dll" ] && cp -p "$WINEPREFIX/drive_c/windows/$sys/$f.dll" "$bk/$sys/"; done
      done
    fi
    for arch in x86_64-windows i386-windows x86_64-unix; do
      for f in "$new/$arch"/*; do cp "$f" "$LIB/$arch/${f##*/}.new" && mv -f "$LIB/$arch/${f##*/}.new" "$LIB/$arch/${f##*/}"; done
    done
    # a new prefix gets these from the runtime (wineboot); an existing one keeps real copies of them
    for pair in x86_64-windows:system32 i386-windows:syswow64; do
      arch=${pair%%:*}; sys=${pair##*:}; [ -d "$WINEPREFIX/drive_c/windows/$sys" ] || continue
      for f in $PREFIX_DLLS; do [ -f "$WINEPREFIX/drive_c/windows/$sys/$f.dll" ] && cp "$new/$arch/$f.dll" "$WINEPREFIX/drive_c/windows/$sys/$f.dll"; done
    done
    echo "$DXMT_VERSION" > "$MARK"
    echo "DXMT $DXMT_VERSION installed (previous: ${old:-runtime}, kept in backups/$(basename "$bk"))" ;;
  *) echo "usage: $0 [status|install]"; exit 2 ;;
esac
