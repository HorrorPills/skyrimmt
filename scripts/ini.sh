# INI helpers for Skyrim's files (sourced). Pure bash + awk (shipped code must not need Python). Case-insensitive
# sections/keys like the game; keeps the file's line endings (Skyrim writes CRLF); writes atomically (temp + mv).
#   ini_get <file> <section> <key>              prints the value (empty + status 1 if missing)
#   ini_merge <file> <source-file|->            every key of the source replaces the same key in the same section
#                                               of <file>, or is appended to that section (section added if missing)
#   ini_set <file> <section> <key> <value>      single key (via ini_merge)
#   ini_del <file> <section> <key>              remove a key

ini_get() {
  [ -f "$1" ] || return 1
  awk -v S="$(echo "$2" | tr 'A-Z' 'a-z')" -v K="$(echo "$3" | tr 'A-Z' 'a-z')" '
    { sub(/\r$/, ""); l = $0; t = l; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t ~ /^\[.*\]$/ { sec = tolower(substr(t, 2, length(t) - 2)); next }
    sec == S && index(t, "=") > 1 && substr(t, 1, 1) != ";" {
      k = substr(t, 1, index(t, "=") - 1); gsub(/[ \t]+$/, "", k)
      if (tolower(k) == K) { v = substr(t, index(t, "=") + 1); gsub(/^[ \t]+/, "", v); print v; found = 1; exit }
    }
    END { exit !found }' "$1"
}

ini_merge() {
  local f=$1 src=$2 tmp
  [ "$src" = - ] && { src=$(mktemp); cat > "$src"; trap "rm -f '$src'" RETURN; }
  [ -f "$f" ] || : > "$f"
  tmp="$f.tmp.$$"
  awk -v SRC="$src" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN {
      sec = ""
      while ((getline l < SRC) > 0) {
        sub(/\r$/, "", l); t = trim(l)
        if (t == "" || substr(t, 1, 1) == ";") continue
        if (t ~ /^\[.*\]$/) { sec = tolower(substr(t, 2, length(t) - 2)); if (!(sec in hassec)) { hassec[sec] = 1; order[++ns] = sec; hdr[sec] = t }; continue }
        if (index(t, "=") < 2) continue
        k = trim(substr(t, 1, index(t, "=") - 1)); v = trim(substr(t, index(t, "=") + 1))
        key = sec SUBSEP tolower(k)
        if (!(key in want)) { nk[sec]++; keys[sec, nk[sec]] = tolower(k) }
        want[key] = k "=" v
      }
      nl = "\n"; sec = ""
    }
    function flush(s,   i, kk) { for (i = 1; i <= nk[s]; i++) { kk = s SUBSEP keys[s, i]; if (!(kk in done)) { out[++no] = want[kk]; done[kk] = 1 } } }
    { if ($0 ~ /\r$/) nl = "\r\n"; l = $0; sub(/\r$/, "", l); t = trim(l)
      if (t ~ /^\[.*\]$/) { flush(sec); sec = tolower(substr(t, 2, length(t) - 2)); seen[sec] = 1; out[++no] = l; next }
      if (index(t, "=") > 1 && substr(t, 1, 1) != ";") {
        kk = sec SUBSEP tolower(trim(substr(t, 1, index(t, "=") - 1)))
        if (kk in want) { out[++no] = want[kk]; done[kk] = 1; next }
      }
      out[++no] = l }
    END {
      flush(sec)
      for (i = 1; i <= ns; i++) if (!(order[i] in seen) && order[i] != "") { out[++no] = hdr[order[i]]; flush(order[i]) }
      for (i = 1; i <= no; i++) printf "%s%s", out[i], nl
    }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

ini_set() { printf '[%s]\n%s=%s\n' "$2" "$3" "$4" | ini_merge "$1" -; }

ini_del() {
  [ -f "$1" ] || return 0
  local tmp="$1.tmp.$$"
  awk -v S="$(echo "$2" | tr 'A-Z' 'a-z')" -v K="$(echo "$3" | tr 'A-Z' 'a-z')" '
    { l = $0; sub(/\r$/, "", l); t = l; gsub(/^[ \t]+|[ \t]+$/, "", t) }
    t ~ /^\[.*\]$/ { sec = tolower(substr(t, 2, length(t) - 2)) }
    sec == S && index(t, "=") > 1 { k = substr(t, 1, index(t, "=") - 1); gsub(/[ \t]+$/, "", k); if (tolower(k) == K) next }
    { print }' "$1" > "$tmp" && mv -f "$tmp" "$1"
}
