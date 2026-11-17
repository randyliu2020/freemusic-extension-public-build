#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fm-native-download-format-tests.XXXXXX")"
trap 'rm -f "$test_dir/FMNativeDownloadFormatTests"; rmdir "$test_dir"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
  -DFMX_DOWNLOAD_INTEGRATION_TESTING=1 -mmacosx-version-min=12.0 \
  -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
  FMQualityResolver.m FMJSDownloadCoordinator.m FMDownloadIntegration.m FMNativeDownloadFormatTests.m \
  -o "$test_dir/FMNativeDownloadFormatTests"
"$test_dir/FMNativeDownloadFormatTests" "${1:-$PWD/download-format-tests.json}"
