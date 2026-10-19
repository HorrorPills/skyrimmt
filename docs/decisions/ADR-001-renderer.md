# ADR-001: Renderer path

Status: **Accepted provisionally under the owner's overnight autopilot mandate (2026-10-17); owner confirms at G0.**

## Decision
Use **DXMT** (the D3D11→Metal layer already in the runtime as Wine's builtin d3d11/dxgi) with SkyrimMT's
`dxmt_purevirtual_return.sh` binary fix for Skyrim's stray Release. No own Metal renderer.

## Why (docs/m1-report.md)
* DXMT + fix runs Skyrim correctly; DXVK 2.4.1/MoltenVK can't create a D3D11 device; wined3d isn't in the runtime.
* At Skyrim's default 60 fps cap, pacing is near perfect (p99 16.9 ms). Uncapped, Medium reaches ~115 fps and Low
  ~119 fps; Ultra/High are GPU-limited (~92–97 fps). Translation overhead isn't the limiter worth a custom renderer.

## Consequences
* Frame pacing default = Skyrim's 60 lock; "120" mode requires SSE Display Tweaks (physics) and a lighter preset.
* M8 candidates (bounded): newer DXMT built with the source fix (needs Xcode), per-setting 120 preset, shader-cache
  prewarm if first-visit stalls show up.
