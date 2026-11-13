#!/bin/bash
# The Metal renderer (DXMT) pinned in config/release.conf, newer than the runtime's v0.80: fixes the black shadows
# that follow characters (issue #2) and the stray-Release crash itself (DXMT 66277b8), so the
# binary patch (tools/wine-patches/dxmt_purevirtual_return.sh) isn't needed with it.
# The pinned build's own shaders are Metal 3.2 (macOS 15): older macOS can't load them and the game renders nothing
# (black screen, issue #24). Below DXMT_MIN_MACOS the runtime's own DXMT (v0.80, Metal 3.1) is the one to have, and an
# install that has the pinned build gets the runtime's back.
#   scripts/dxmt.sh [status]   up-to-date | outdated <installed> | no-runtime
#   scripts/dxmt.sh wanted     the build this Mac should have: DXMT_VERSION, or "runtime"
#   scripts/dxmt.sh install    install what's wanted into the runtime and the prefix: the pinned build (download to cache/,
#                              verify, record wine/.dxmt-build), or the runtime's own back (from backups/, else the
#                              runtime archive; wine/.dxmt-build removed)
# Wine must not be running (its processes keep the old files). The DXMT it replaces is kept in backups/dxmt-<version>.
# SKYRIMMT_DXMT=<file> installs from a local archive instead of DXMT_URL (checksum still verified).
# SKYRIMMT_MACOS_VERSION=<x.y> stands in for this Mac's macOS version (tests).
. "$(dirname "$0")/_env.sh"
. "$SKYRIMMT_ROOT/config/release.conf" 2>/dev/null || true   # DXMT_VERSION / DXMT_URL / DXMT_SHA256 / DXMT_MIN_MACOS, RUNTIME_*
MARK="$SKYRIM_HOME/wine/.dxmt-build"
LIB="$SKYRIM_HOME/wine/lib/wine"
PREFIX_DLLS="d3d11 dxgi d3d10core winemetal"   # the prefix's real copies (its nvapi64/nvngx are Wine stubs: left alone)
ARCHS="x86_64-windows i386-windows x86_64-unix"

dxmt_version() { /usr/bin/perl -0777 -ne 'print $1 if /DXMT D3D\0+([\x21-\x7e]{2,40})\0/' "$1" 2>/dev/null; }
installed() { cat "$MARK" 2>/dev/null || dxmt_version "$LIB/x86_64-windows/d3d11.dll"; }
macos_major() { local v="${SKYRIMMT_MACOS_VERSION:-$(/usr/bin/sw_vers -productVersion 2>/dev/null)}"; echo "${v%%.*}"; }
wanted() {   # the pinned build, unless this macOS can't run it
  [ -n "${DXMT_VERSION:-}" ] || { echo runtime; return; }
  local m; m=$(macos_major)
  if [ -n "${DXMT_MIN_MACOS:-}" ] && [ "${m:-0}" -lt "$DXMT_MIN_MACOS" ] 2>/dev/null; then echo runtime; else echo "$DXMT_VERSION"; fi
}
# the prefix keeps real copies: they must match the runtime's, or the game still runs the old build
prefix_matches() {
  local pair arch sys f
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    arch=${pair%%:*}; sys=${pair##*:}
    for f in $PREFIX_DLLS; do
      [ -f "$WINEPREFIX/drive_c/windows/$sys/$f.dll" ] && ! cmp -s "$LIB/$arch/$f.dll" "$WINEPREFIX/drive_c/windows/$sys/$f.dll" && { echo "$f.dll"; return 1; }
    done
  done
  return 0
}
status() {
  [ -d "$LIB" ] || { echo no-runtime; return; }
  local want v bad; want=$(wanted)
  if [ "$want" = runtime ]; then
    # the runtime's own: nothing of ours recorded (the pinned build records itself in .dxmt-build)
    [ -f "$MARK" ] && { echo "outdated $(cat "$MARK")"; return; }
    [ -n "${DXMT_VERSION:-}" ] || { echo up-to-date; return; }   # nothing pinned at all: never touched
    v=$(installed)
  else
    v=$(installed); [ "$v" = "$want" ] || { echo "outdated ${v:-unknown}"; return; }
  fi
  bad=$(prefix_matches) || { echo "outdated $v (prefix copy of $bad differs)"; return; }
  echo up-to-date
}

# $1 = folder to fill with the runtime's own DXMT (<arch>/<file> for ARCHS): the copy kept when the pinned build
# replaced it, else the files from the runtime archive (setup.sh's cached download, or downloaded again and verified)
runtime_dxmt() {
  local dest=$1 want_files bk v arch f
  # the files the pinned build replaced are the ones to put back: the runtime's DXMT set
  want_files="x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll x86_64-windows/d3d10core.dll x86_64-windows/winemetal.dll
    x86_64-windows/nvapi64.dll x86_64-windows/nvngx.dll i386-windows/d3d11.dll i386-windows/dxgi.dll i386-windows/d3d10core.dll
    i386-windows/winemetal.dll x86_64-unix/winemetal.so"
  # the runtime's DXMT version: its pristine copy in share/dxmt (the pinned build never touches that folder)
  v=$(dxmt_version "$SKYRIM_HOME/wine/share/dxmt/x86_64-windows/d3d11.dll")
  for bk in ${v:+"$SKYRIM_HOME/backups/dxmt-$v"} "$SKYRIM_HOME/backups/dxmt-runtime"; do
    [ -d "$bk" ] || continue
    local ok=1; for f in $want_files; do [ -f "$bk/$f" ] || { ok=0; break; }; done
    [ $ok = 1 ] || continue
    [ "$(dxmt_version "$bk/x86_64-windows/d3d11.dll")" = "${v:-$(dxmt_version "$bk/x86_64-windows/d3d11.dll")}" ] || continue
    for f in $want_files; do mkdir -p "$dest/${f%/*}"; cp -p "$bk/$f" "$dest/$f" || return 1; done
    echo "backups/$(basename "$bk")"; return 0
  done
  [ -n "${RUNTIME_URL:-}" ] && [ -n "${RUNTIME_SHA256:-}" ] || return 1
  local tarball="$SKYRIM_HOME/cache/$(basename "$RUNTIME_URL")"
  if ! echo "$RUNTIME_SHA256  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$tarball.part" "$RUNTIME_URL" && mv "$tarball.part" "$tarball" || return 1
    echo "$RUNTIME_SHA256  $tarball" | shasum -a 256 -c - >/dev/null 2>&1 || return 1
  fi
  local members=""; for f in $want_files; do members="$members wine/lib/wine/$f"; done
  mkdir -p "$dest/x" && tar -xJf "$tarball" -C "$dest/x" $members || return 1
  for f in $want_files; do mkdir -p "$dest/${f%/*}"; mv "$dest/x/wine/lib/wine/$f" "$dest/$f" || return 1; done
  rm -rf "$dest/x"
  echo "$(basename "$tarball")"
}

# copy <arch>/<file> from $1 into the runtime, and the prefix's copies of PREFIX_DLLS
put_in_place() {
  local new=$1 arch f pair sys
  for arch in $ARCHS; do
    [ -d "$new/$arch" ] || continue
    for f in "$new/$arch"/*; do cp "$f" "$LIB/$arch/${f##*/}.new" && mv -f "$LIB/$arch/${f##*/}.new" "$LIB/$arch/${f##*/}" || return 1; done
  done
  # a new prefix gets these from the runtime (wineboot); an existing one keeps real copies of them
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    arch=${pair%%:*}; sys=${pair##*:}; [ -d "$WINEPREFIX/drive_c/windows/$sys" ] || continue
    for f in $PREFIX_DLLS; do [ -f "$WINEPREFIX/drive_c/windows/$sys/$f.dll" ] && { cp "$new/$arch/$f.dll" "$WINEPREFIX/drive_c/windows/$sys/$f.dll" || return 1; }; done
  done
  return 0
}

case "${1:-status}" in
  status) status ;;
  wanted) wanted ;;
  install)
    st=$(status)
    [ "$st" = up-to-date ] && { echo "DXMT $(installed) already installed"; exit 0; }
    [ "$st" = no-runtime ] && { echo "no Wine runtime in $SKYRIM_HOME"; exit 1; }
    stop_idle_wine || { echo "Wine is running in $SKYRIM_HOME — quit Skyrim and Steam first"; exit 1; }
    mkdir -p "$SKYRIM_HOME/cache"
    work=$(mktemp -d "$SKYRIM_HOME/cache/dxmt.XXXXXX"); trap 'rm -rf "$work"' EXIT
    if [ "$(wanted)" = runtime ]; then
      old=$(installed)
      from=$(runtime_dxmt "$work/rt") || { echo "could not get the runtime's own DXMT back (no backup, runtime download failed)"; exit 1; }
      put_in_place "$work/rt" || { echo "could not copy DXMT into $SKYRIM_HOME"; exit 1; }
      rm -f "$MARK"
      echo "DXMT $(installed) (the runtime's own) back in place: macOS $(macos_major) can't run DXMT ${old:-?}'s Metal 3.2 shaders (from $from)"
      exit 0
    fi
    src="${SKYRIMMT_DXMT:-$DXMT_URL}"; archive="$src"
    if [[ $src == http* ]]; then
      archive="$SKYRIM_HOME/cache/$(basename "$src")"
      if ! echo "$DXMT_SHA256  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$archive.part" "$src" && mv "$archive.part" "$archive" || { echo "DXMT download failed"; exit 1; }
      fi
    fi
    echo "$DXMT_SHA256  $archive" | shasum -a 256 -c - >/dev/null 2>&1 || { echo "DXMT checksum mismatch ($archive)"; exit 1; }
    tar -xzf "$archive" -C "$work" || { echo "could not unpack $archive"; exit 1; }
    new=$(dirname "$(find "$work" -path '*/x86_64-windows/d3d11.dll' | head -1)"); new=${new%/x86_64-windows}
    [ -f "$new/x86_64-unix/winemetal.so" ] && [ -f "$new/i386-windows/d3d11.dll" ] || { echo "unexpected DXMT archive layout"; exit 1; }
    old=$(installed); bk="$SKYRIM_HOME/backups/dxmt-${old:-runtime}"
    if [ ! -d "$bk" ]; then   # first replacement of that version: keep it (runtime + prefix copies)
      for arch in $ARCHS; do
        mkdir -p "$bk/$arch"; for f in "$new/$arch"/*; do [ -f "$LIB/$arch/${f##*/}" ] && cp -p "$LIB/$arch/${f##*/}" "$bk/$arch/"; done
      done
      for sys in system32 syswow64; do
        mkdir -p "$bk/$sys"; for f in $PREFIX_DLLS; do [ -f "$WINEPREFIX/drive_c/windows/$sys/$f.dll" ] && cp -p "$WINEPREFIX/drive_c/windows/$sys/$f.dll" "$bk/$sys/"; done
      done
    fi
    put_in_place "$new" || { echo "could not copy DXMT into $SKYRIM_HOME"; exit 1; }
    echo "$DXMT_VERSION" > "$MARK"
    echo "DXMT $DXMT_VERSION installed (previous: ${old:-runtime}, kept in backups/$(basename "$bk"))" ;;
  *) echo "usage: $0 [status|wanted|install]"; exit 2 ;;
esac
