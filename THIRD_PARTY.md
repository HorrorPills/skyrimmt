# Third-party components

SkyrimMT's own code (scripts, launcher, mod manager, patch tools) contains no code copied from the projects below.

## Wine runtime
SkyrimMT currently uses the **tf2mt runtime** (`tf2mt-runtime-wine10.0-0.6.11.tar.xz`, published in the tf2mt
v0.1.0 release; URL + SHA-256 in `config/release.conf`). Setup clones a local tf2mt runtime of the same version
(APFS clone, original `winemac.so` restored) or downloads that asset. It redistributes these components unmodified:

| Component | Version | License | Source |
|---|---|---|---|
| Wine (Sikarugir build, wine-staging based) | 10.0 (`WS12WineSikarugir10.0_6`) | LGPL-2.1-or-later | https://gitlab.winehq.org/wine/wine · https://github.com/Sikarugir-App |
| DXVK | 2.4.1 | zlib | https://github.com/doitsujin/dxvk |
| MoltenVK | 1.4.1 | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| DXMT | as bundled (d3d11.dll dated 2025-07-10; exact version to be confirmed in M1) | LGPL-2.1 | https://github.com/3Shain/dxmt |
| vkd3d | bundled with Wine | LGPL-2.1-or-later | https://gitlab.winehq.org/wine/vkd3d |

**Audio mix rate:** `tools/wine-patches/coreaudio_rate.sh` changes one instruction in Wine's `winecoreaudio.so`
(`unix_get_mix_format`, `dlls/winecoreaudio.drv/coreaudio.c`) so Wine reports a fixed mix rate (96 kHz by default,
like CrossOver's audio setting) instead of the device's; applied locally, original kept in
`$SKYRIM_HOME/backups/winecoreaudio.so.orig`, reverted by choosing "Device rate". `tools/wine-patches/coreaudio_period.sh`
changes the driver's default device period from 10 to 30 ms (`def_period`), which removes the output underruns that
cause crackling with Microsoft's XAudio2 (measured with `tools/audiotap`).

**Modification:** on the user's machine, `tools/wine-patches/winemac_warp_nodiscard.sh` (from tf2mt) binary-patches
two instructions in Wine's `winemac.so` so mouse motion isn't discarded on cursor warps. The shipped runtime is
unmodified; the patch is applied locally (original kept in `$SKYRIM_HOME/backups/winemac.so.orig`) and can be
reverted. Corresponding Wine source: `dlls/winemac.drv/cocoa_app.m`, `-[WineApplicationController
setCursorPosition:]`, Wine 10.0.

## Separate programs
* **skyrimmt-loot** (`Contents/Helpers/skyrimmt-loot`, source `helpers/loot/`): LOOT sorting built on libloot 0.29
  (GPL-3.0, https://github.com/loot/libloot); the helper is GPL-3.0 (LICENSE bundled). SkyrimMT runs it and reads JSON.
  The LOOT masterlist/prelude (github.com/loot/skyrimse, github.com/loot/prelude; CC0-1.0) are
  downloaded on the user's machine, not bundled.
* **Pandora Behaviour Engine+** (GPL-3.0-or-later, https://github.com/Monitor221hz/Pandora-Behaviour-Engine-Plus):
  native macOS arm64 build of commit `1f26bbc` (v5.0.0-beta) with `tools/pandora/macos.patch` (path separators,
  `--tesv`/`-o` honoured, CRLF text output; each change commented), built by `tools/pandora/build.sh` into
  `$SKYRIM_HOME/tools/pandora` (.NET runtime self-contained, MIT). SkyrimMT runs it as a separate program and keeps its
  output as a mod. Any binary distribution ships with the patched source (upstream URL + commit + patch).
* **BodySlide and Outfit Studio** (GPL-3.0, https://github.com/ousnius/BodySlide-and-Outfit-Studio): native macOS
  arm64 build of tag `v6.0.0` with `tools/bodyslide/macos.patch` (GLEW on macOS, two clang fixes, no window updates
  from build threads, `--noninteractive` and `--buildlist` for unattended builds, CPU decoding of BC4/BC5/BC7 textures
  for the preview because macOS OpenGL lacks them — decoders from bc7enc by Rich Geldreich, MIT or public domain,
  `tools/bodyslide/third_party/bc7enc`), built by `tools/bodyslide/build.sh`
  (`-ffp-contract=off`: output byte-identical to the Windows release) into `$SKYRIM_HOME/tools/bodyslide` with bundled
  wxWidgets (wxWindows Library Licence), GLEW (BSD/MIT) and their image libraries. Run as a separate program; any
  binary distribution ships with the patched source.
* **Wabbajack installer engine — jackify-engine** (GPL-3.0, https://github.com/Omni-guides/dev-jackify-engine, a fork
  of https://github.com/wabbajack-tools/wabbajack): native macOS arm64 build of commit `9bba792` (v0.5.10) with
  `tools/wabbajack/macos.patch` (SkyrimMT Wine shim instead of Proton for texconv/texdiag, game/data folder overrides,
  Microsoft.Data.Sqlite (MIT) instead of System.Data.SQLite for osx-arm64, Nexus checked only when needed, stack traces
  logged), built by `tools/wabbajack/build.sh` into `$SKYRIM_HOME/tools/wabbajack`. Bundles Microsoft's texconv/texdiag
  (DirectXTex, MIT) and 7-Zip (LGPL-2.1) as shipped upstream. Run as a separate program; source + patch accompany any
  binary distribution.
* **Distribution of the three native tools above:** prebuilt archives (`pandora-`, `bodyslide-`,
  `wabbajack-macos-arm64.tar.xz`) are attached to each SkyrimMT release together with their complete patched sources
  (`*-source.tar.xz`). SkyrimMT downloads a tool the first time a profile needs it and verifies its SHA-256
  (`config/release.conf`).
* **Microsoft XAudio2 2.7 and d3dcompiler_47** (Microsoft redistributable licence): downloaded on demand from Microsoft
  (DirectX June 2010 redistributable; d3dcompiler_47 10.0.28000 from Microsoft's Windows SDK NuGet package
  Microsoft.Windows.SDK.CPP, only the DLL's bytes fetched) into the Wine environment for correct 3D audio and shader
  compilation; not bundled.
* **7-Zip for macOS** (`7zz`, LGPL-2.1 + unRAR restriction, https://github.com/ip7z/7zip): downloaded on demand into
  `$SKYRIM_HOME/tools/7zip` (checksum from the release) when the system unpacker can't open an archive; not bundled.
* **DepotDownloader** (GPL-2.0, https://github.com/SteamRE/DepotDownloader): downloaded on demand into
  `$SKYRIM_HOME/tools/depotdownloader` for the Skyrim version switcher; runs under the user's own Steam login.

## Reference only (no code used)
* Nexus Mod Manager (GPL-2, https://github.com/Nexus-Mods/Nexus-Mod-Manager): behaviour reference for the mod manager.
* Mudcrab (MIT/Apache-2.0): plugin-format reference.

**Not included and never redistributed:** Steam, Skyrim and any Bethesda content, SKSE, and any mods. Mods are
downloaded only through the user's own Nexus Mods account.
