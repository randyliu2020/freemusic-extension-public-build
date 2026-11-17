#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fm-native-download-tests.XXXXXX")"
trap 'rm -f "$test_dir/FMDownloadIntegrationTests"; rmdir "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
  -DFMX_DOWNLOAD_INTEGRATION_TESTING=1 -mmacosx-version-min=12.0 \
  -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
  FMQualityResolver.m FMJSDownloadCoordinator.m FMDownloadIntegration.m FMDownloadIntegrationTests.m \
  -o "$test_dir/FMDownloadIntegrationTests"
"$test_dir/FMDownloadIntegrationTests" "${1:-$PWD/native-download-tests.json}"
