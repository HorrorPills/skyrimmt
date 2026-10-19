# ADR-002: SkyrimMT licence

Status: **Accepted — option A (MIT)**, 2026-10-19

## Context
Nexus Mod Manager (the behaviour model) is GPL-2; libloot is GPL-3; tf2mt is MIT.

## Options
* **A (recommended):** SkyrimMT stays MIT. The mod manager (ModKit) is written clean-room from public docs (FOMOD
  schema, Nexus API docs, UESP plugin format) and observed NMM behaviour; no NMM code is copied. LOOT ships as a
  separate GPL-3 helper executable (source + licence in `helpers/loot/`, JSON over a pipe).
* **B:** SkyrimMT is GPL-3, and NMM logic may be ported more directly.

## Decision
A: SkyrimMT is MIT. The LOOT helper and the patched native tools (Pandora, BodySlide, Wabbajack engine) are separate
GPL-3.0 programs, published with their sources.
