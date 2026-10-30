#!/bin/bash
# Install Skyrim Anniversary Edition from the player's own GOG offline installers (gog.com → Games → Skyrim →
# "Download offline backup game installers", Windows): the base game (setup_the_elder_scrolls_v_skyrim_special_edition_
# *.exe + its .bin parts) and the Anniversary Upgrade DLC (setup_the_elder_scrolls_v_skyrim_anniversary_upgrade_*.exe +
# .bin), in one folder (subfolders like DLC/ are searched too). GOG's Inno Setup installers run silently in SkyrimMT's
# prefix and install into $GOG_GAMEDIR; nothing is downloaded. Makes this game environment a GOG one (config/store).
#   install-gog.sh check <folder>               what was found (FOUND/INFO/FAIL lines); changes nothing
#   install-gog.sh install <folder> [--lang L] [--interactive]
#                                               base game, then the upgrade (STEP/PROGRESS/OK/FAIL lines, DONE at the end)
#   install-gog.sh language <L>                 switch the installed game's language (no reinstall)
#   install-gog.sh report                       which language the installed game is set up for (text, voices, fonts,
#                                               GOG registry); changes nothing. Also written at the end of every install.
# --lang: the game language (english, russian, german, …); default from the Mac's preferred language. GOG's installer
#   puts every language's voices and a Skyrim_Default_<xx>.ini per language into the game folder; its silent mode takes
#   /LANG as its own window language only (registry after a silent /LANG=russian install, 2026-10-26:
#   installer_language=russian, language=english), so the game language is applied afterwards (set_language).
# --interactive: GOG's installer windows instead of a silent install (choose the game language there; --lang then only
#   if given). Each installer also writes Inno Setup's own log: logs/gog-setup-*.log.
# Needs the Wine runtime and prefix (scripts/setup.sh); finishes by running setup.sh again (Skyrim INI defaults).
set -u
. "$(dirname "$0")/_env.sh"; . "$(dirname "$0")/ini.sh"
BASE_PAT='setup_the_elder_scrolls_v_skyrim_special_edition_*.exe'
AE_PAT='setup_the_elder_scrolls_v_skyrim_anniversary_upgrade_*.exe'
WIN_DIR='C:\GOG Games\Skyrim Anniversary Edition'   # = $GOG_GAMEDIR
LOG="$SKYRIM_HOME/logs/install-gog.log"

fail() { echo "FAIL $1"; exit 1; }
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1073741824 }'; }
# newest installer matching $2 in folder $1 (the folder itself or one level down)
find_setup() { find "$1" -maxdepth 2 -type f -iname "$2" 2>/dev/null | LC_ALL=C sort | tail -1; }
# "<bytes> <parts>" of installer $1 and its .bin parts (setup-1.bin … setup-N.bin next to it); fails when there is no
# part or one is missing (a gap in the numbers)
setup_size() {
  local base=${1%.*} n=1 all total
  total=$(stat -f %z "$1")
  all=$(find "$(dirname "$1")" -maxdepth 1 -type f -name "$(basename "$base")-*.bin" | wc -l | tr -d ' ')
  while [ -f "$base-$n.bin" ]; do total=$((total + $(stat -f %z "$base-$n.bin"))); n=$((n + 1)); done
  [ $n -gt 1 ] && [ "$all" -eq $((n - 1)) ] && echo "$total $((n - 1))"
}

# check <folder>: sets BASE_EXE, AE_EXE and NEED (bytes in the installers ≈ size of the installed game)
check() {
  local dir=$1 p s
  [ -d "$dir" ] || fail "folder not found: $dir"
  # browsers keep unfinished downloads as *.download (Safari), *.crdownload (Chrome), *.part (Firefox)
  p=$(find "$dir" -maxdepth 2 \( -name '*.download' -o -name '*.crdownload' -o -name '*.part' \) 2>/dev/null | head -1)
  [ -z "$p" ] || fail "still downloading: $(basename "$p") — wait until every file has finished"
  BASE_EXE=$(find_setup "$dir" "$BASE_PAT")
  [ -n "$BASE_EXE" ] || fail "no Skyrim installer here (expected setup_the_elder_scrolls_v_skyrim_special_edition_….exe from GOG)"
  s=$(setup_size "$BASE_EXE") || fail "base game: download every $(basename "${BASE_EXE%.*}")-N.bin (numbered 1, 2, 3… without a gap)"
  NEED=${s% *}
  echo "FOUND base game: $(basename "$BASE_EXE") + ${s#* } parts ($(gib "$NEED"))"
  AE_EXE=$(find_setup "$dir" "$AE_PAT")
  if [ -n "$AE_EXE" ]; then
    s=$(setup_size "$AE_EXE") || fail "Anniversary Upgrade: download every $(basename "${AE_EXE%.*}")-N.bin (numbered 1, 2, 3… without a gap)"
    NEED=$((NEED + ${s% *}))
    echo "FOUND Anniversary Upgrade: $(basename "$AE_EXE") + ${s#* } parts ($(gib "${s% *}"))"
  else
    echo "INFO no Anniversary Upgrade installer (setup_the_elder_scrolls_v_skyrim_anniversary_upgrade_….exe) — Special Edition only"
  fi
}

lang_default() {   # Inno Setup language names as GOG's installers use them
  case $(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/^[^a-z]*\([a-z][a-z]\).*/\1/p') in
    ru) echo russian ;; de) echo german ;; fr) echo french ;; es) echo spanish ;; it) echo italian ;;
    pl) echo polish ;; ja) echo japanese ;; *) echo english ;;
  esac
}

lang_code() {   # language name → GOG's lang_code (its first two letters name the Skyrim_Default_<xx>.ini)
  case $1 in
    russian) echo ru-RU ;; german) echo de-DE ;; french) echo fr-FR ;; spanish) echo es-ES ;; italian) echo it-IT ;;
    polish) echo pl-PL ;; japanese) echo ja-JP ;; english) echo en-US ;; *) return 1 ;;
  esac
}

installed_kb() { du -sk "$GOG_GAMEDIR" 2>/dev/null | cut -f1; }
winpath() { printf 'Z:%s' "$(printf '%s' "$1" | tr '/' '\\')"; }   # Wine's Z: drive is the Mac's /

# ini_changed <old.ini> <new.ini>: the keys of <new> whose value differs from <old> (or that <old> lacks), as an INI
# for ini_merge
ini_changed() {
  LC_ALL=C awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    FNR == 1 { sec = "" }
    { sub(/\r$/, ""); t = trim($0) }
    t == "" || substr(t, 1, 1) == ";" { next }
    t ~ /^\[.*\]$/ { sec = substr(t, 2, length(t) - 2); next }
    index(t, "=") < 2 { next }
    { k = trim(substr(t, 1, index(t, "=") - 1)); v = trim(substr(t, index(t, "=") + 1)); id = tolower(sec) SUBSEP tolower(k) }
    FILENAME == ARGV[1] { old[id] = v; next }
    !(id in old) || old[id] != v { if (sec != last) { print "[" sec "]"; last = sec }; print k "=" v }
  ' "$1" "$2"
}

# set_language <name>: the game language, as GOG's installer sets it — its Skyrim_Default_<xx>.ini becomes
# Skyrim_Default.ini, and GOG's registry record says so. My Games/Skyrim.ini (copied from the default at the game's
# first start) gets the keys that differ between the two defaults; a copy of it goes to backups/ first.
set_language() {
  local name=$1 code src changed mg="$MYGAMES_DIR/Skyrim.ini" key
  code=$(lang_code "$name") || { echo "FAIL unknown language $name (english, russian, german, french, spanish, italian, polish, japanese)"; return 1; }
  src=$(find "$GOG_GAMEDIR" -maxdepth 1 -iname "Skyrim_Default_${code%%-*}.ini" | head -1)
  [ -n "$src" ] || { echo "FAIL no Skyrim_Default_${code%%-*}.ini in the game folder — this GOG build has no $name"; return 1; }
  changed=$(ini_changed "$GOG_GAMEDIR/Skyrim_Default.ini" "$src")
  cp "$src" "$GOG_GAMEDIR/Skyrim_Default.ini" || { echo "FAIL could not write Skyrim_Default.ini"; return 1; }
  if [ -f "$mg" ] && [ -n "$changed" ]; then
    mkdir -p "$SKYRIM_HOME/backups"; cp -p "$mg" "$SKYRIM_HOME/backups/Skyrim.ini.before-$name"
    printf '%s\n' "$changed" | ini_merge "$mg" -
  fi
  # GOG's records (base game and upgrade) whose path is this game folder
  for key in $("$WINE" reg query 'HKLM\Software\Wow6432Node\GOG.com\Games' /s 2>/dev/null | LC_ALL=C tr -d '\r' |
               LC_ALL=C awk -v P="$WIN_DIR" '/^HKEY/ { k = $0 } $1 == "path" && index($0, P) { print k }'); do
    "$WINE" reg add "$key" /v language /t REG_SZ /d "$name" /f >/dev/null 2>&1
    "$WINE" reg add "$key" /v lang_code /t REG_SZ /d "$code" /f >/dev/null 2>&1
  done
  echo "OK game language: $name ($(basename "$src")$([ -f "$mg" ] && [ -n "$changed" ] && echo ", My Games Skyrim.ini updated"))"
}

# report: how the installed game's language is set up — INI lines, voice archives, loose strings/fonts, GOG registry
report() {
  local g=$GOG_GAMEDIR f k
  [ -f "$g/SkyrimSE.exe" ] || fail "Skyrim (GOG) is not installed in $g"
  echo "INFO game version: $("$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/^game_version=//p')"
  for f in "$g/Skyrim_Default.ini" "$g/Skyrim.ini" "$MYGAMES_DIR/Skyrim.ini" "$MYGAMES_DIR/SkyrimCustom.ini"; do
    [ -f "$f" ] || continue
    echo "INI ${f#"$SKYRIM_HOME"/}"
    LC_ALL=C tr -d '\r' < "$f" | LC_ALL=C grep -iE '^[[:space:]]*(sLanguage|sResourceArchiveList2?)[[:space:]]*=' | sed 's/^/    /'
  done
  echo "FILES language INIs: $(find "$g" -maxdepth 1 -iname 'Skyrim_Default_*.ini' -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')"
  echo "FILES voice archives: $(find "$g/Data" -maxdepth 1 -iname '*voices*.bsa' -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')"
  echo "FILES interface archives: $(find "$g/Data" -maxdepth 1 -iname '*interface*.bsa' -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')"
  echo "FILES loose strings: $(find "$g/Data/Strings" -maxdepth 1 -iname '*.*strings' 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/.*_\([a-z]*\)\.[a-z]*strings$/\1/' | LC_ALL=C sort -u | tr '\n' ' ')"
  echo "FILES loose fonts/translations: $(find "$g/Data/Interface" \( -iname 'font*' -o -iname 'translat*' \) 2>/dev/null | sed "s|^$g/||" | tr '\n' ' ')"
  echo "FILES other language-tagged files: $(find "$g" -maxdepth 3 -type f \( -iname '*_ru*' -o -iname '*russian*' -o -iname '*_en[0-9.]*' -o -iname '*english*' \) 2>/dev/null | sed "s|^$g/||" | grep -viE 'voices' | head -20 | tr '\n' ' ')"
  for k in 'HKLM\Software\Wow6432Node\GOG.com\Games' 'HKLM\Software\GOG.com\Games'; do
    "$WINE" reg query "$k" /s 2>/dev/null | LC_ALL=C tr -d '\r' | LC_ALL=C grep -iE 'HKEY|lang|gameName|ver' | sed "s/^/REG /"
  done
}

# run_setup <installer.exe>: silent install into $GOG_GAMEDIR. Progress = growth of the game folder against NEED,
# counted from START_KB (the folder before the first installer), so both installers make one 0–99 % run.
run_setup() {
  local exe=$1 pid rc now pct quiet slog
  # Inno Setup's own log (selected language, components, tasks, every file) next to ours
  slog="$SKYRIM_HOME/logs/gog-setup-$(basename "$exe" | sed 's/^setup_the_elder_scrolls_v_skyrim_//; s/_[0-9].*//').log"
  quiet="/VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /SP-"; [ "$INTERACTIVE" = 1 ] && quiet=""
  echo "== $(date '+%F %T') $(basename "$exe") /LANG=$LANG_NAME ${quiet:-(interactive)} → $(basename "$slog")" >> "$LOG"
  # shellcheck disable=SC2086
  (cd "$(dirname "$exe")" && exec "$WINE" "$(basename "$exe")" $quiet /NORESTART /NOICONS "/DIR=$WIN_DIR" "/LANG=$LANG_NAME" \
     "/LOG=$(winpath "$slog")" >> "$LOG" 2>&1) &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    sleep 5
    now=$(installed_kb); pct=$(( ( (${now:-0} - START_KB) * 1024 * 100 ) / NEED ))
    [ $pct -lt 0 ] && pct=0; [ $pct -gt 99 ] && pct=99
    echo "PROGRESS $pct"
  done
  wait $pid; rc=$?
  echo "   exit $rc" >> "$LOG"
  return $rc
}

USAGE="usage: install-gog.sh check|install <folder with the GOG installers> [--lang L] [--interactive] | language <L> | report"
cmd=${1:-}; dir=${2:-}
if [ "$cmd" = report ]; then follow_session_sync; report; echo "DONE"; exit 0; fi
if [ "$cmd" = language ]; then
  [ -n "$dir" ] || { echo "$USAGE"; exit 2; }
  is_gog && [ -f "$GOG_GAMEDIR/SkyrimSE.exe" ] || fail "Skyrim (GOG) is not installed"
  game_running && fail "quit Skyrim first"
  follow_session_sync; set_language "$(echo "$dir" | tr 'A-Z' 'a-z')" || exit 1; echo "DONE"; exit 0
fi
[ -n "$cmd" ] && [ -n "$dir" ] || { echo "$USAGE"; exit 2; }
shift 2
LANG_NAME=$(lang_default); INTERACTIVE=0; LANG_GIVEN=0
while [ $# -gt 0 ]; do
  case $1 in
    --lang) LANG_NAME=$(echo "${2:?--lang needs a name}" | tr 'A-Z' 'a-z'); LANG_GIVEN=1; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

case $cmd in
  check) check "$dir"; echo "DONE" ;;
  install)
    check "$dir"
    [ -x "$WINE" ] && [ -f "$WINEPREFIX/system.reg" ] || fail "the Wine environment is not ready — run setup first"
    game_running && fail "quit Skyrim first"
    if ! is_gog && [ -f "$STEAM_GAMEDIR/SkyrimSE.exe" ]; then
      fail "this game folder has Skyrim from Steam — choose another game folder in Setup for the GOG version"
    fi
    # free space: the installers unpack about their own size; a reinstall reuses what is there
    have=$(installed_kb); have=${have:-0}
    avail=$(df -k "$SKYRIM_HOME" | awk 'NR == 2 { print $4 }')
    want_kb=$(( NEED / 1024 + 2 * 1048576 - have ))
    [ "$avail" -ge "$want_kb" ] || fail "not enough disk space: $(gib $((want_kb * 1024))) needed, $(gib $((avail * 1024))) free"

    mkdir -p "$SKYRIM_HOME/config" "$SKYRIM_HOME/logs" "$SKYRIM_HOME/run"
    echo gog > "$SKYRIM_HOME/config/store"
    unset GAMEDIR; . "$SKYRIMMT_ROOT/scripts/_env.sh"   # GOG folders from here on
    RUN="$SKYRIM_HOME/run"
    echo $$ > "$RUN/tool-pending"; trap 'rm -f "$RUN/tool-pending"' EXIT   # session-helper.sh keeps the session alive
    server_up || record_session_sync
    follow_session_sync
    START_KB=$have

    echo "STEP Installing Skyrim Special Edition (GOG, language: $LANG_NAME)…"
    run_setup "$BASE_EXE" || fail "the GOG installer stopped (exit $?) — see $LOG"
    [ -f "$GOG_GAMEDIR/SkyrimSE.exe" ] || fail "the installer finished but SkyrimSE.exe is missing — see $LOG"
    if [ -n "$AE_EXE" ]; then
      echo "STEP Installing the Anniversary Upgrade…"
      run_setup "$AE_EXE" || fail "the Anniversary Upgrade installer stopped (exit $?) — see $LOG"
      # Special Edition has 4 Creation Club files, the upgrade adds the rest (70+)
      cc=$(find "$GOG_GAMEDIR/Data" -maxdepth 1 -iname 'cc*.es[lmp]' 2>/dev/null | wc -l | tr -d ' ')
      [ "$cc" -gt 10 ] || echo "INFO the Anniversary Upgrade added no Creation Club files ($cc found) — see $LOG"
    fi
    echo "PROGRESS 100"
    v=$("$SKYRIMMT_ROOT/scripts/settings.sh" status | sed -n 's/^game_version=//p')
    echo "OK Skyrim ${v:-?} (GOG) installed in $GOG_GAMEDIR"
    # the game language (a silent install leaves GOG's default, English); in the installer's windows the player chose it
    if [ "$INTERACTIVE" = 0 ] || [ "$LANG_GIVEN" = 1 ]; then set_language "$LANG_NAME" | sed 's/^FAIL /INFO /'; fi
    { echo "== $(date '+%F %T') language report"; report; } | tee -a "$LOG" | sed 's/^/INFO /'
    "$SKYRIMMT_ROOT/scripts/setup.sh" | grep -v '^DONE$'   # INI defaults now that the game is there
    echo "DONE"
    ;;
  *) echo "$USAGE"; exit 2 ;;
esac
