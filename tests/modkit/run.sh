#!/bin/bash
# Build ModKit + its test runner with swiftc and run it: tests/modkit/run.sh [all|unit|property|crash|bench]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; mkdir -p "$ROOT/build"
swiftc -O "$ROOT"/app/ModKit/*.swift "$ROOT/tests/modkit/main.swift" "$ROOT/tests/modkit/install_tests.swift" "$ROOT/tests/modkit/nexus_tests.swift" "$ROOT/tests/modkit/pandora_tests.swift" "$ROOT/tests/modkit/bodyslide_tests.swift" "$ROOT/tests/modkit/mo2_tests.swift" "$ROOT/tests/modkit/profile_tests.swift" "$ROOT/tests/modkit/updates_tests.swift" "$ROOT/tests/modkit/crash_tests.swift" "$ROOT/tests/modkit/save_tests.swift" "$ROOT/tests/modkit/scale_tests.swift" "$ROOT/tests/modkit/cleaning_tests.swift" "$ROOT/tests/modkit/slots_tests.swift" -o "${MODKIT_TESTS_BIN:-$ROOT/build/modkit-tests}"
cd "$ROOT" && exec "${MODKIT_TESTS_BIN:-$ROOT/build/modkit-tests}" "$@"
