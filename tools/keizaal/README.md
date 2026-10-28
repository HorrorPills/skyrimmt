# Keizaal Online support files

`NirnLabUIPlatform.dll`: Keizaal's NirnLabUIPlatform 3.3 (CEF in-game UI) with CPU frames under Wine, so the UI shows
on macOS (DXMT can't open Chromium's shared texture on Wine 10: `DeviceTexture: Invalid device handle`).
Built from https://github.com/jbjanot/NirnLabUIPlatform/tree/wine-cpu-paint (commit 6bb3c43, on top of
skyrim-roleplay/NirnLabUIPlatform c9514ac), proposed upstream in https://github.com/skyrim-roleplay/NirnLabUIPlatform/pull/1.
MIT licence: `LICENSE-NirnLabUIPlatform`.

`scripts/keizaal.sh` puts it in place only over the exact DLL Keizaal ships (SHA-256 below), never over another version:
- original: `b2f564afc796ed7c07c3a2993d229fa13aa20b1fc9ba23767229adc1519d13cf`
- patched:  `dda65cf961df75a2cd6914462b8d08b18dc56e1e888256f160d9612db3a88257`

Remove both once Keizaal ships a NirnLabUIPlatform with the fix.
