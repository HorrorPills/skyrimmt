# ADR-003: Deploy mods as APFS clones (not hardlinks)

Status: Accepted (2026-10-17, autopilot; measured)

## Context
PLAN §8.8 proposed hardlinks (NMM-style) with clonefile/copy fallbacks. Measured on the owner's Mac (APFS):
link(2) 263 µs per file (127 µs with 8 threads), clonefile(2) 96 µs (67 µs with 8 threads). A 182k-file deploy
took 70.6 s with sequential hardlinks. Hardlinks also share the inode with staging: a tool that edits a deployed file
in place silently changes the mod's staging copy (PLAN §8.8 "hardlink caveat").

## Decision
Place files with clonefile(2) in parallel; fall back to link(2), then copy (keeping mtime). Clones share data blocks
(no extra disk space) but are independent files. Ownership checks: inode (link) or size + nanosecond mtime
(clone/copy; clonefile preserves mtime).

## Consequences
* First deploy of 182k files: 18.3 s (vs 70.6 s); everyday changes 1–2 s.
* Staging and Data must be on the same APFS volume for clones (else link/copy fallback; copies cost space).
* A tool edit makes the deployed clone diverge from staging; verify() reports it and purge keeps it ("kept modified").
  The Overwrite-mod capture (M7) builds on this.
