#!/bin/bash
# Translations take the same format arguments as their English keys (a mismatch crashes the app when shown).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; mkdir -p "$ROOT/build"
swiftc -O "$ROOT/tests/l10n/check.swift" -o "$ROOT/build/l10n-check" 2>/dev/null
exec "$ROOT/build/l10n-check" "$ROOT/app/Resources"
