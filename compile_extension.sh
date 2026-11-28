#!/bin/bash
# Shared device/simulator build. Only authored source is accepted here.
set -euo pipefail
source_dir="$1"
sdk="$2"
target="$3"
output="$4"
mode="$5"
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
object_dir="$(mktemp -d "${TMPDIR:-/tmp}/fmx-extension-objects.XXXXXX")"
# macOS ships Bash 3.2: set -u treats an empty array as unset. Keep the
# common flags in both arrays, so device builds also expand nonempty arrays.
objc_flags=(-fobjc-arc -fblocks)
swift_flags=(-swift-version 5)
if [[ "$mode" == simulator ]]; then
  objc_flags+=(-DFMX_LOCKSCREEN_TESTING=1 -DFMX_LISTENING_CAPTURE_TESTING=1 -DFMX_PLAYBACK_CACHE_TESTING=1 -DFMX_ADAPTIVE_PLAYBACK_TESTING=1 -DFMX_PLAYBACK_QUALITY_TESTING=1)
  swift_flags+=(-D FMX_ADAPTIVE_PLAYBACK_TESTING -D FMX_PLAYBACK_QUALITY_TESTING)
elif [[ "$mode" != device ]]; then
  echo 'Unknown extension build mode' >&2
  exit 2
fi
sources=(FMExtension LXSourceRuntime FMExtensionProtocol FMLockScreen FMArtworkSelection FMSettingsEntry FMSearchPreferences FMSettingsMigration FMQishuiSearch FMListeningHistory FMInsights FMInteraction FMLXMC FMLXMCUI FMLXMCLocalStore FMLXMCLocalProtocol FMNavigation FMListeningCapture FMPlaybackCache FMReplayCache FMReplayMedia FMPlaylistEditor FMDownloadArtwork FMDownloadArtworkIntegration FMNativeDownloadCoverDisplay FMQualityResolver FMAdaptivePlayback FMPlaybackSequence FMPlaybackQualityDisplay FMTrackMetadata FMJSDownloadCoordinator FMDownloadIntegration)
objects=()
for source in "${sources[@]}"; do
  object="$object_dir/$source.o"
  xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdk_path" \
    -c -Os -Wall -Wextra -Wno-unused-parameter \
    -Werror=implicit-function-declaration -I "$source_dir" "${objc_flags[@]}" \
    "$source_dir/$source.m" -o "$object"
  objects+=("$object")
done
# Swift constructs real Foundation.URL / String values at the native ABI boundary.
xcrun --sdk "$sdk" swiftc -target "$target" -sdk "$sdk_path" \
  -parse-as-library -emit-library -module-name FMExtension \
  -O "${swift_flags[@]}" "${objects[@]}" \
  "$source_dir/FMAdaptivePlaybackBridge.swift" "$source_dir/FMPlaybackQualityBridge.swift" "$source_dir/FMNativeDownloadCoverModel.swift" "$source_dir/FMLyricGesture.swift" \
  -Xlinker -install_name -Xlinker '@executable_path/Frameworks/FMExtension.dylib' \
  -Xlinker -current_version -Xlinker 1.5.0 \
  -Xlinker -compatibility_version -Xlinker 1.0.0 \
  -Xlinker -headerpad_max_install_names \
  -framework Foundation -framework UIKit -framework JavaScriptCore \
  -framework UniformTypeIdentifiers -framework Security -framework MediaPlayer \
  -framework AVFoundation -framework CoreVideo -framework CoreMedia \
  -framework CoreGraphics -framework ImageIO -framework Vision -framework AudioToolbox -lz -o "$output"
