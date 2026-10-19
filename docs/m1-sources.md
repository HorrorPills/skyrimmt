# M1 — sources for Skyrim facts (owner rule: check wikis, don't guess)

| Fact | Source |
|---|---|
| 1.7.104 = current PC patch (2026-08-27); previous 1.6.1170 (2024-01-17) | https://en.uesp.net/wiki/Skyrim:Special_Edition_Patch |
| SKSE64 AE build 2.3.1 supports 1.7.104 | https://skse.silverlock.org/ |
| AE / Creation Club content is downloaded in-game (Creations menu, Bethesda.net), not by Steam | https://en.uesp.net/wiki/Skyrim:Creation (via search) |
| SSE Display Tweaks unofficial update 0.5.21 (SlavicPotato): 1.7.99–1.7.104, SKSE 2.3.0+, Address Library AIO v13+ | https://www.nexusmods.com/skyrimspecialedition/mods/189739 (search snippet; Nexus blocks WebFetch) |
| `steam_appid.txt` in the game folder makes SteamAPI_RestartAppIfNecessary return false (no relaunch via Steam → Bethesda launcher) | https://partner.steamgames.com/doc/sdk/api#initialization_and_shutdown |
| Console key = "tilde key" near 1/Esc (layout dependent); `coc <cell>` e.g. `coc Riverwood`, `coc qasmoke`; `save <name>` (quote names with spaces) | https://en.uesp.net/wiki/Skyrim:Console |
| `bat <file>`: batch files in Skyrim root (no extension) or `Data\<file>.txt`; **COC inside a batch file crashes to desktop** | https://en.uesp.net/wiki/Skyrim:Console |
| `coc Riverwood` from the main menu skips the intro | community sources via search (fictionhorizon, Steam discussions); verify in-game |
| `sStartingConsoleCommand` does not work in SSE | Nexus mod 38624 posts (via search) |
| SkyrimPrefs [Display] bFull Screen / iSize W / iSize H; iPresentInterval belongs in Skyrim.ini ([Display]) — 0 = vsync off | https://stepmodifications.org/wiki/Guide:SkyrimPrefs_INI/Display |
| Record header 24 bytes (type, dataSize u32, flags u32, formID u32, timestamp u16, VC u16, version u16, unknown u16); field = type[4] + size u16 + data; `XXXX` field carries a u32 size for the next field; GRUP header 24 bytes | https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format |
| TES4 flags: 0x1 master (ESM), 0x80 localized, 0x200 light (ESL). Subrecords HEDR (f32 version, u32 records, u32 next id), CNAM author, SNAM description, MAST master name + DATA u64 pairs, ONAM, INTV, INCC | https://en.uesp.net/wiki/Skyrim_Mod:Mod_File_Format/TES4 |
| SE load order = order in plugins.txt (Windows-1252); official Bethesda plugins (main master, DLC, Creation Club) hardcoded to load first; masters before non-masters; light plugins share slot FE, separate limit 4096; ≤255 full active plugins | libloadorder docs (github.com/Ortham/libloadorder doc/src: load_order_mechanisms.md, active_plugins.md) — documentation only, no code |
| Plugin type (SE): master if .esm or master flag; light master if .esl or master+light flags; light non-master if .esp + light flag; else full non-master | libloadorder doc/src/plugin_types.md |
| Nexus API v1 base `https://api.nexusmods.com/v1/`, header `apikey`; endpoints users/validate.json, games/{g}/mods/{id}.json, …/files.json, …/files/{f}.json, …/files/{f}/download_link.json (+ key, expires for non-premium), games/{g}/mods/md5_search/{md5}.json, games/{g}/mods/updated.json?period=1d/1w/1m; SSO wss://sso.nexusmods.com + browser `https://www.nexusmods.com/sso?id=<uuid>&application=<slug>` | pynxm source (github.com/GandaG/pynxm, Apache-2.0; facts only) |
| Nexus AUP: send Application-Name/Application-Version; personal API keys only for testing/personal use; public apps must register (support, testing build) and use SSO with their own slug; no scraping/rehosting; never use keys without a user action | https://help.nexusmods.com/article/114-api-acceptable-use-policy |

## Depot manifests (scripts/versions.sh), checked 2026-10-18
| Version | depot:manifest | Sources |
|---|---|---|
| 1.6.1170 | 489831:8442952117333549665 489832:8042843504692938467 489833:1914580699073641964 | earlier two guides + https://wiki.wildlandermod.com/09-How-Do-i/HowDoI/downgrade/ |
| 1.5.97 | 489831:7848722008564294070 489832:8702665189575304780 489833:2289561010626853674 | https://www.nexusmods.com/skyrimspecialedition/articles/6547 + https://stepmodifications.org/forum/topic/16280-howto-reinstall-skyrim-se-1597-if-you-dont-have-a-backup/ |
| 1.6.640 | not added yet — needs two agreeing sources (Steam guides were rate-limited) | |
