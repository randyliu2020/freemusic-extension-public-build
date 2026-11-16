#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/lx-runtime-tests.XXXXXX")"
trap 'rm -f "$test_dir/LXRuntimeTests"; rmdir "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -mmacosx-version-min=12.0 -framework Foundation -framework JavaScriptCore \
  -framework Security LXSourceRuntime.m LXRuntimeTests.m -o "$test_dir/LXRuntimeTests"
"$test_dir/LXRuntimeTests" "$PWD/LXBootstrap.js"
