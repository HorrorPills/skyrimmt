#!/bin/bash
# Binary patch for the runtime's DXMT d3d11.dll (x86_64, tf2mt runtime 0.6.11): a pure virtual call logs
# "Pure virtual function called" and RETURNS 0 instead of aborting. Uses only tools that ship with macOS.
#
# Why: Skyrim SE releases a texture and its SRV one time too many. Windows and DXVK tolerate the extra Release on the
# freed object; in DXMT the vtable left after destruction is the abstract D3D11ResourceCommon/view base, so the call
# lands in __cxa_pure_virtual, which aborts (Skyrim exits right after the Bethesda logo). neutron's source fix
# (github.com/codeWonderland/neutron PR #59) gives those bases no-op AddRef/Release; building DXMT needs Xcode +
# the Metal toolchain, so this patches the same effect into the handler: Release on a destroyed object returns 0.
# Every occurrence is still logged (DXMT's "err:" line), so we can count them.
# Patch (verified against original bytes first):
#   __cxa_pure_virtual+0x3d (file 0x1a2ad)  ud2 ; mov %rax,%rbx ; lea…   ->  add $0x40,%rsp ; pop %rbx ; xor %eax,%eax ; ret
# Applied to the builtin (lib/wine/x86_64-windows) and the prefix's system32 copy.
# Usage: dxmt_purevirtual_return.sh apply|revert|status
set -u
SKYRIM_HOME="${SKYRIM_HOME:-$HOME/Games/skyrim}"
FILES=("$SKYRIM_HOME/wine/lib/wine/x86_64-windows/d3d11.dll" "$SKYRIM_HOME/prefix/drive_c/windows/system32/d3d11.dll")
BACKUP="$SKYRIM_HOME/backups/dxmt-d3d11.dll.orig"
OFF=107181                    # 0x1a2ad
ORIG=0f0b4889c3488d4c
NEW=4883c4405b31c0c3

bytes_at() { /usr/bin/xxd -p -s "$OFF" -l 8 "$1" | tr -d '\n'; }
state() { local b; b=$(bytes_at "$1"); [ "$b" = "$ORIG" ] && echo original || { [ "$b" = "$NEW" ] && echo patched || echo unknown; }; }
overall() {   # state of all files: original | patched | unknown | mixed
  local s first=""; for f in "${FILES[@]}"; do [ -f "$f" ] || { echo unknown; return; }; s=$(state "$f"); [ -z "$first" ] && first=$s; [ "$s" = "$first" ] || { echo mixed; return; }; done; echo "$first"
}

st=$(overall)
case "${1:-status}" in
  status) echo "$st" ;;
  apply)
    [ "$st" = patched ] && { echo "already patched"; exit 0; }
    for f in "${FILES[@]}"; do s=$(state "$f"); [ "$s" = original ] || [ "$s" = patched ] || { echo "unexpected d3d11.dll contents in $f (different DXMT build?) — not patching"; exit 1; }; done
    [ -f "$BACKUP" ] || { mkdir -p "$(dirname "$BACKUP")"; cp -p "${FILES[0]}" "$BACKUP"; }
    for f in "${FILES[@]}"; do
      [ "$(state "$f")" = patched ] && continue
      cp "$f" "$f.new"; echo -n "$NEW" | /usr/bin/xxd -r -p | dd of="$f.new" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
      [ "$(state "$f.new")" = patched ] || { rm -f "$f.new"; echo "patch verification failed"; exit 1; }
      mv -f "$f.new" "$f"   # running processes keep the old inode
    done
    echo "patched (backup: $BACKUP)" ;;
  revert)
    [ -f "$BACKUP" ] || { echo "no backup at $BACKUP"; exit 1; }
    for f in "${FILES[@]}"; do cp "$BACKUP" "$f.new" && mv -f "$f.new" "$f"; done; echo "reverted to original" ;;
  *) echo "usage: $0 apply|revert|status"; exit 2 ;;
esac
