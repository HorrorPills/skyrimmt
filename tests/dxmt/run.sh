#!/bin/bash
# scripts/dxmt.sh: which DXMT a Mac gets, and switching between the pinned build and the runtime's own (issue #24: the
# pinned build's shaders need macOS 15, so older macOS keeps v0.80). No Wine, no network: a fake runtime, prefix and
# archives (file:// URLs) with the same layout as the real ones; SKYRIMMT_MACOS_VERSION stands in for the Mac's macOS.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/skyrimmt-dxmt.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL $1 (got '$2', expected '$3')"; fi; }
ok()    { if "$@"; then echo yes; else echo no; fi; }

# a copy of the scripts with its own release.conf (scripts find config/ next to themselves)
mkdir -p "$T/root"; cp -R "$ROOT/scripts" "$ROOT/config" "$T/root/"
FILES="x86_64-windows/d3d11.dll x86_64-windows/dxgi.dll x86_64-windows/d3d10core.dll x86_64-windows/winemetal.dll
  x86_64-windows/nvapi64.dll x86_64-windows/nvngx.dll i386-windows/d3d11.dll i386-windows/dxgi.dll i386-windows/d3d10core.dll
  i386-windows/winemetal.dll x86_64-unix/winemetal.so"
dxmt_files() {   # $1 = folder, $2 = version: DXMT files whose d3d11.dll carries the version string like the real ones
  local f; for f in $FILES; do mkdir -p "$1/${f%/*}"; printf '%s %s' "$2" "$f" > "$1/$f"; done
  printf 'MZ fake\0DXMT D3D\0\0%s\0rest' "$2" > "$1/x86_64-windows/d3d11.dll"
}
# runtime archive (v0.80, as the tf2mt runtime holds it) and the pinned build's archive (a commit-named top folder)
mkdir -p "$T/src/rt/wine/lib/wine" "$T/src/pin/0123abcd"
dxmt_files "$T/src/rt/wine/lib/wine" v0.80
dxmt_files "$T/src/pin/0123abcd" testpin
tar -cJf "$T/runtime.tar.xz" -C "$T/src/rt" wine
tar -czf "$T/dxmt-testpin.tar.gz" -C "$T/src/pin" 0123abcd
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
conf() {   # $1 = DXMT_MIN_MACOS (empty: none), $2 = runtime checksum
  cat > "$T/root/config/release.conf" <<EOF
RUNTIME_VERSION="9.9.9"
RUNTIME_URL="file://$T/runtime.tar.xz"
RUNTIME_SHA256="$2"
DXMT_VERSION="testpin"
DXMT_URL="https://example.invalid/dxmt-testpin.tar.gz"   # SKYRIMMT_DXMT points at the local archive
DXMT_SHA256="$(sha "$T/dxmt-testpin.tar.gz")"
${1:+DXMT_MIN_MACOS=$1}
EOF
}
conf 15 "$(sha "$T/runtime.tar.xz")"

H="$T/home"   # a game folder with the runtime as setup.sh unpacks it, and a prefix with real copies of 4 DLLs
fresh() {
  rm -rf "$H"; mkdir -p "$H/wine/share/dxmt" "$H/prefix/drive_c/windows/system32" "$H/prefix/drive_c/windows/syswow64" "$H/cache" "$H/backups"
  dxmt_files "$H/wine/lib/wine" v0.80
  dxmt_files "$H/wine/share/dxmt" v0.80; rm -rf "$H/wine/share/dxmt/x86_64-unix"   # the runtime's pristine copy: Windows side only
  for f in d3d11 dxgi d3d10core winemetal; do
    cp "$H/wine/lib/wine/x86_64-windows/$f.dll" "$H/prefix/drive_c/windows/system32/"; cp "$H/wine/lib/wine/i386-windows/$f.dll" "$H/prefix/drive_c/windows/syswow64/"
  done
}
dx() { SKYRIM_HOME=$H SKYRIMMT_MACOS_VERSION=$MAC SKYRIMMT_DXMT="$T/dxmt-testpin.tar.gz" "$T/root/scripts/dxmt.sh" "$@"; }
same_as() {   # runtime + prefix copies hold exactly the DXMT in $1
  local f; for f in $FILES; do cmp -s "$H/wine/lib/wine/$f" "$1/$f" || return 1; done
  for f in d3d11 dxgi d3d10core winemetal; do
    cmp -s "$H/prefix/drive_c/windows/system32/$f.dll" "$1/x86_64-windows/$f.dll" && cmp -s "$H/prefix/drive_c/windows/syswow64/$f.dll" "$1/i386-windows/$f.dll" || return 1
  done
}
RT="$T/src/rt/wine/lib/wine"; PIN="$T/src/pin/0123abcd"

echo "== macOS 15+: the pinned build"
fresh; MAC=15.1
check "wanted" "$(dx wanted)" testpin
check "status before" "$(dx status)" "outdated v0.80"
dx install >/dev/null
check "installed" "$(dx status)" up-to-date
check "runtime and prefix hold the pinned build" "$(ok same_as "$PIN")" yes
check "recorded" "$(cat "$H/wine/.dxmt-build")" testpin
check "the runtime's own kept" "$(ok cmp -s "$H/backups/dxmt-v0.80/x86_64-unix/winemetal.so" "$RT/x86_64-unix/winemetal.so")" yes
MAC=27.2; check "macOS 27: same" "$(dx status)" up-to-date

echo "== macOS 14: the runtime's own comes back (from its backup)"
MAC=14.6.1
check "wanted" "$(dx wanted)" runtime
check "status" "$(dx status)" "outdated testpin"
out=$(dx install); check "install succeeds" "$?" 0
check "says where from" "$(echo "$out" | grep -c 'backups/dxmt-v0.80')" 1
check "back to v0.80" "$(dx status)" up-to-date
check "runtime and prefix hold v0.80" "$(ok same_as "$RT")" yes
check "no pinned build recorded" "$(ok test -e "$H/wine/.dxmt-build")" no
check "nothing more to do" "$(dx install)" "DXMT v0.80 already installed"
check "a fresh setup on macOS 14 keeps v0.80" "$(fresh; dx status)" up-to-date

echo "== macOS 14, no backup: from the runtime archive"
fresh; MAC=15.0; dx install >/dev/null; rm -rf "$H/backups/dxmt-v0.80"
MAC=13.7; dx install >/dev/null
check "back to v0.80" "$(dx status)" up-to-date
check "runtime and prefix hold v0.80" "$(ok same_as "$RT")" yes
check "archive kept in cache" "$(ok test -f "$H/cache/runtime.tar.xz")" yes

echo "== macOS 14, incomplete backup: from the runtime archive"
fresh; MAC=15.0; dx install >/dev/null; rm "$H/backups/dxmt-v0.80/x86_64-unix/winemetal.so"
MAC=14.0; dx install >/dev/null
check "runtime and prefix hold v0.80" "$(ok same_as "$RT")" yes

echo "== a damaged download changes nothing"
fresh; MAC=15.0; dx install >/dev/null; rm -rf "$H/backups/dxmt-v0.80"
conf 15 0000000000000000000000000000000000000000000000000000000000000000
MAC=14.0; dx install >/dev/null; check "install fails" "$?" 1
check "the pinned build stays, whole" "$(ok same_as "$PIN")" yes
check "and recorded" "$(cat "$H/wine/.dxmt-build")" testpin
conf 15 "$(sha "$T/runtime.tar.xz")"

echo "== no minimum macOS configured: the pinned build everywhere (as before)"
conf "" "$(sha "$T/runtime.tar.xz")"
fresh; MAC=14.0
check "wanted" "$(dx wanted)" testpin
dx install >/dev/null; check "installed" "$(ok same_as "$PIN")" yes

echo "$pass passed, $fail failed"
[ $fail = 0 ]
