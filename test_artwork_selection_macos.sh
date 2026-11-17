#!/bin/bash
# Cloud macOS only: real Swift optional storage and Objective-C ownership, with
# AddressSanitizer. All temporary objects stay under the runner's temporary dir.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
report="${1:-$root/artwork-selection-tests.json}"
temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fmx-artwork-selection.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -O1 -g -fsanitize=address -I "$root" \
  -c "$root/FMArtworkSelection.m" -o "$temporary/bridge.o"
xcrun --sdk macosx clang -fobjc-arc -fblocks -O1 -g -fsanitize=address -I "$root" \
  -c "$root/FMArtworkSelectionTests.m" -o "$temporary/tests.o"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -g -sanitize=address \
  -import-objc-header "$root/FMArtworkSelection.h" "$root/FMArtworkSelectionFixture.swift" \
  "$temporary/bridge.o" "$temporary/tests.o" -framework Foundation -o "$temporary/artwork-tests"
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 "$temporary/artwork-tests" "$report"
