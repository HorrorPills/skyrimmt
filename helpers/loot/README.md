# skyrimmt-loot

LOOT load-order sorting for SkyrimMT, built on [libloot](https://github.com/loot/libloot) (GPL-3.0). This helper is a
separate program, licensed GPL-3.0 (see LICENSE); SkyrimMT runs it and reads its JSON output (no linking).

Build: `cargo build --release` (Rust toolchain via rustup). Masterlist: github.com/loot/skyrimse (branch v0.29),
prelude: github.com/loot/prelude (v0.29); SkyrimMT downloads and caches both.
