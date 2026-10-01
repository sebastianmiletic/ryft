#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -D RYFT_STANDALONE_TESTS \
    "$ROOT"/Sources/RyftWindowLayout/*.swift \
    "$ROOT"/Tests/RyftWindowLayoutTests/*.swift \
    "$ROOT/scripts/test-layout.swift" -o "$TEMP/layout-tests"
"$TEMP/layout-tests"
