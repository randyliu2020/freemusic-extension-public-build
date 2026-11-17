#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fm-lxmc-local-tests.XXXXXX")"
trap 'rm -f "$test_dir/FMLXMCLocalTests"; rmdir "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
  -mmacosx-version-min=12.0 -framework Foundation \
  FMLXMC.m FMLXMCLocalStore.m FMLXMCLocalProtocol.m FMTrackMetadata.m \
  FMExtensionProtocol.m FMQishuiSearch.m FMLXMCLocalTests.m -lz \
  -o "$test_dir/FMLXMCLocalTests"
"$test_dir/FMLXMCLocalTests" "${1:-$PWD/local-playlist-tests.json}"
