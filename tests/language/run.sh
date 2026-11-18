#!/bin/bash
# sync_game_language (scripts/_env.sh, issue #27): Steam's per-game language reaches My Games/Skyrim.ini the way the
# Bethesda launcher would bring it (SkyrimMT starts the game without that launcher) — but only the language's values
# (sLanguage, voice archive, font file) change, only after Steam's language changed (per Skyrim.ini: profiles with own
# INIs count separately), and never for version folders or GOG. No Wine or Steam needed.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/skyrimmt-language.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL $1 (got '$2', expected '$3')"; fi; }
CR=$'\r'; TAB=$'\t'
H="$T/home"; G="$H/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Skyrim Special Edition"
MG="$H/prefix/drive_c/users/${USER:-$(id -un)}/Documents/My Games/Skyrim Special Edition"
mkdir -p "$G" "$MG"
default() {   # default <LANGUAGE> <xx>: Skyrim_Default.ini as Steam installs it for that language (CRLF; a font file
  # for every language but English, as in Steam's Russian Skyrim_Default.ini)
  printf '[General]\r\nsLanguage=%s\r\nsTestFile1=Dawnguard.esm\r\n' "$1" > "$G/Skyrim_Default.ini"
  [ "$1" = ENGLISH ] || printf '[Fonts]\r\nsFontConfigFile=Interface\\FontConfig_%s.txt\r\n' "$2" >> "$G/Skyrim_Default.ini"
  printf '[Archive]\r\nsResourceArchiveList=Skyrim - Misc.bsa, Skyrim - Interface.bsa\r\nsResourceArchiveList2=Skyrim - Voices_%s0.bsa, Skyrim - Textures0.bsa, Skyrim - Textures1.bsa\r\n' "$2" >> "$G/Skyrim_Default.ini"
}
run() { ( export SKYRIM_HOME="$H" "$@"; unset GAMEDIR; . "$ROOT/scripts/_env.sh" 2>/dev/null; sync_game_language ); }
get() { ( . "$ROOT/scripts/ini.sh"; ini_get "$1" "$2" "$3" ); }
INI="$MG/Skyrim.ini"; MARK="$H/config/game-language"

echo "== English Steam (the default): nothing changes"
default ENGLISH en; cp "$G/Skyrim_Default.ini" "$INI"; printf '[Display]\r\nfGamma=1.2\r\n' >> "$INI"
before=$(shasum < "$INI"); run >/dev/null
check "file untouched" "$(shasum < "$INI")" "$before"
check "language remembered" "$(cat "$MARK")" "*${TAB}ENGLISH"

echo "== Steam switched to Russian (issue #27)"
default RUSSIAN ru; out=$(run)
check "sLanguage" "$(get "$INI" General sLanguage)" RUSSIAN
check "voice archive" "$(get "$INI" Archive sResourceArchiveList2)" "Skyrim - Voices_ru0.bsa, Skyrim - Textures0.bsa, Skyrim - Textures1.bsa"
check "Cyrillic font file" "$(get "$INI" Fonts sFontConfigFile)" 'Interface\FontConfig_ru.txt'
check "own setting kept" "$(get "$INI" Display fGamma)" 1.2
check "other keys kept" "$(get "$INI" General sTestFile1)" Dawnguard.esm
check "CRLF kept" "$(grep -c "$CR\$" "$INI")" "$(wc -l < "$INI" | tr -d ' ')"
check "reported" "$out" "game language: ENGLISH → RUSSIAN (Steam's language setting)"
check "remembered" "$(cat "$MARK")" "*${TAB}RUSSIAN"

echo "== a language set by hand stays until Steam's changes"
( . "$ROOT/scripts/ini.sh"; ini_set "$INI" General sLanguage GERMAN ); before=$(shasum < "$INI"); run >/dev/null
check "hand-set language kept" "$(shasum < "$INI")" "$before"

echo "== Steam back to English"
default ENGLISH en; run >/dev/null
check "sLanguage" "$(get "$INI" General sLanguage)" ENGLISH
check "voice archive" "$(get "$INI" Archive sResourceArchiveList2)" "Skyrim - Voices_en0.bsa, Skyrim - Textures0.bsa, Skyrim - Textures1.bsa"
check "language font file removed" "$(get "$INI" Fonts sFontConfigFile || echo none)" none

echo "== a font mod's own font file stays"
default RUSSIAN ru; run >/dev/null
( . "$ROOT/scripts/ini.sh"; ini_set "$INI" Fonts sFontConfigFile 'Interface\MyFonts\fontconfig.txt' )
default ENGLISH en; run >/dev/null
check "custom font file kept" "$(get "$INI" Fonts sFontConfigFile)" 'Interface\MyFonts\fontconfig.txt'

echo "== a font mod's font file stays when Steam switches to Russian too"
default ENGLISH en; run >/dev/null; default RUSSIAN ru; run >/dev/null
check "custom font file kept" "$(get "$INI" Fonts sFontConfigFile)" 'Interface\MyFonts\fontconfig.txt'
check "language still applied" "$(get "$INI" General sLanguage)" RUSSIAN
( . "$ROOT/scripts/ini.sh"; ini_del "$INI" Fonts sFontConfigFile )

echo "== profiles with their own INIs (Wabbajack / MO2 imports) count separately"
rm -f "$MARK"; default RUSSIAN ru; mkdir -p "$H/config/modkit" "$H/profiles/Default" "$H/profiles/GTS/ini"
echo Default > "$H/config/modkit/current-profile"
printf '[General]\r\nsLanguage=ENGLISH\r\n' > "$INI"; run >/dev/null
check "shared INI: applied" "$(get "$INI" General sLanguage)" RUSSIAN
# switch to the list's profile: ModKit puts its own (English) Skyrim.ini in My Games
echo GTS > "$H/config/modkit/current-profile"; printf '[General]\r\nsLanguage=ENGLISH\r\n' > "$H/profiles/GTS/ini/Skyrim.ini"
cp "$H/profiles/GTS/ini/Skyrim.ini" "$INI"; out=$(run)
check "own-INI profile: applied as well" "$(get "$INI" General sLanguage)" RUSSIAN
check "remembered per Skyrim.ini" "$(sort "$MARK" | tr '\t\n' ':|')" "*:RUSSIAN|GTS:RUSSIAN|"
( . "$ROOT/scripts/ini.sh"; ini_set "$INI" General sLanguage GERMAN ); before=$(shasum < "$INI"); run >/dev/null
check "own-INI profile: hand-set language kept" "$(shasum < "$INI")" "$before"
rm -rf "$H/config/modkit" "$H/profiles"

echo "== modlist INI: long archive list, voices in the middle, other spacing"
rm -f "$MARK"; default RUSSIAN ru
printf '[General]\r\nsLanguage=ENGLISH\r\n[Archive]\r\nsResourceArchiveList2=Skyrim - Textures0.bsa,Skyrim - Voices_en0.bsa,  Skyrim - Textures8.bsa, Skyrim - Patch.bsa\r\nbInvalidateOlderFiles=1\r\n' > "$INI"
run >/dev/null
check "first start, Russian Steam: applied" "$(get "$INI" General sLanguage)" RUSSIAN
check "only the voice archive swapped" "$(get "$INI" Archive sResourceArchiveList2)" "Skyrim - Textures0.bsa, Skyrim - Voices_ru0.bsa, Skyrim - Textures8.bsa, Skyrim - Patch.bsa"
check "neighbour key kept" "$(get "$INI" Archive bInvalidateOlderFiles)" 1

echo "== first start, English Steam, Russian set by hand: kept"
rm -f "$MARK"; default ENGLISH en
printf '[General]\r\nsLanguage=RUSSIAN\r\n' > "$INI"; before=$(shasum < "$INI"); run >/dev/null
check "hand-set language kept" "$(shasum < "$INI")" "$before"

echo "== INI without an archive list"
rm -f "$MARK"; default RUSSIAN ru; printf '[General]\r\nsLanguage=ENGLISH\r\n' > "$INI"; run >/dev/null
check "sLanguage" "$(get "$INI" General sLanguage)" RUSSIAN
check "no archive list added" "$(get "$INI" Archive sResourceArchiveList2 || echo none)" none

echo "== Skyrim.INI spelled as the launcher writes it"
rm -f "$MARK" "$INI"; printf '[General]\r\nsLanguage=ENGLISH\r\n' > "$MG/Skyrim.INI"; run >/dev/null
check "found, changed" "$(get "$MG/Skyrim.INI" General sLanguage)" RUSSIAN
check "no second file" "$(ls "$MG" | grep -ci '^skyrim\.ini$')" 1
rm -f "$MG/Skyrim.INI"

echo "== no Skyrim.ini yet: the launcher's copy"
rm -f "$MARK"; run >/dev/null
check "created from Skyrim_Default.ini" "$(cmp -s "$G/Skyrim_Default.ini" "$INI" && echo same)" same

echo "== pinned version folder and GOG: untouched"
rm -f "$MARK"; printf '[General]\r\nsLanguage=ENGLISH\r\n' > "$INI"; before=$(shasum < "$INI")
mkdir -p "$H/versions/1.6.1170" "$H/config"; touch "$H/versions/1.6.1170/.skyrimmt-version"; echo 1.6.1170 > "$H/config/game-version"
run >/dev/null; check "version folder" "$(shasum < "$INI")" "$before"
rm -f "$H/config/game-version"; echo gog > "$H/config/store"
run >/dev/null; check "GOG" "$(shasum < "$INI")" "$before"
check "nothing remembered" "$(cat "$MARK" 2>/dev/null)" ""
rm -f "$H/config/store"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
