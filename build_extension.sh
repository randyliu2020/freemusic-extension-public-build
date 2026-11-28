#!/bin/bash
# Compile source only. Never accepts, uploads, extracts or signs the user's IPA.
set -euo pipefail

source_dir="${1:-.}"
output_dir="${2:-dist}"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAILED: building the iOS extension requires macOS and the iPhoneOS SDK" >&2
  exit 2
fi
source_dir="$(cd "$source_dir" && pwd -P)"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
sources=("$source_dir/FMExtension.m" "$source_dir/LXSourceRuntime.m" "$source_dir/FMExtensionProtocol.m" "$source_dir/FMLockScreen.m" "$source_dir/FMSettingsEntry.m" "$source_dir/FMSearchPreferences.m" "$source_dir/FMQishuiSearch.m" "$source_dir/FMListeningHistory.m" "$source_dir/FMInsights.m" "$source_dir/FMInteraction.m" "$source_dir/FMLXMC.m")
sources+=("$source_dir/FMLXMCUI.m" "$source_dir/FMNavigation.m" "$source_dir/FMListeningCapture.m")
sources+=("$source_dir/FMLXMCLocalStore.m" "$source_dir/FMLXMCLocalProtocol.m")
sources+=("$source_dir/FMPlaybackCache.m")
for source_file in "${sources[@]}" "$source_dir/LXBootstrap.js"; do
  if [[ ! -f "$source_file" ]]; then
    echo "FAILED: missing source input: $source_file" >&2
    exit 2
  fi
done
if [[ -e "$output_dir/FMExtension.dylib" || -e "$output_dir/LXBootstrap.js" || -e "$output_dir/build-manifest.json" ]]; then
  echo "FAILED: choose an output directory without existing build artifacts" >&2
  exit 2
fi

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
bash "$source_dir/compile_extension.sh" "$source_dir" iphoneos arm64-apple-ios17.0 "$output_dir/FMExtension.dylib" device
# CommonCrypto symbols are supplied by libSystem; no non-existent CommonCrypto
# framework/library is added. No developer certificate/profile is used here.
cp "$source_dir/LXBootstrap.js" "$output_dir/LXBootstrap.js"
xcrun lipo "$output_dir/FMExtension.dylib" -verify_arch arm64
xcrun otool -hv "$output_dir/FMExtension.dylib"
xcrun otool -L "$output_dir/FMExtension.dylib"
python3 - "$source_dir" "$output_dir" "$sdk_version" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

source_dir, output_dir, sdk_version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.path.insert(0, str(source_dir))
from package_extension import parse_macho, validate_extension_dylib

binary = (output_dir / "FMExtension.dylib").read_bytes()
info = parse_macho(binary, 6)
assert info.platform == 2 and info.minos == 17 << 16
versions = validate_extension_dylib(info)
manifest = {
    "kind": "compiled_extension_only_requires_local_packaging_and_resigning",
    "architecture": "arm64", "platform": "iphoneos", "deployment_target": "17.0",
    "sdk_version": sdk_version, "device_validation": "not performed",
    "dylib_versions": versions,
    "ipa_received_or_uploaded": False,
    "source_sha256": {name: hashlib.sha256((source_dir / name).read_bytes()).hexdigest()
                      for name in ["FMExtension.m", "LXSourceRuntime.m", "LXSourceRuntime.h",
                                   "FMExtensionProtocol.m", "FMExtensionProtocol.h", "LXBootstrap.js",
                                   "FMLockScreen.m", "FMLockScreen.h", "FMSettingsEntry.m", "FMSettingsEntry.h",
                                   "FMSearchPreferences.m", "FMSearchPreferences.h", "FMQishuiSearch.m", "FMQishuiSearch.h",
                                   "FMListeningHistory.m", "FMListeningHistory.h", "FMInsights.m", "FMInsights.h", "FMInteraction.m", "FMInteraction.h", "FMLXMC.m", "FMLXMC.h", "FMLXMCUI.m", "FMLXMCUI.h"]},
    "artifact_sha256": {name: hashlib.sha256((output_dir / name).read_bytes()).hexdigest()
                        for name in ["FMExtension.dylib", "LXBootstrap.js"]},
}
for name in ["FMNavigation.m", "FMNavigation.h", "FMListeningCapture.m", "FMListeningCapture.h", "FMPlaybackCache.m", "FMPlaybackCache.h", "FMQualityResolver.m", "FMQualityResolver.h", "FMAdaptivePlayback.m", "FMAdaptivePlayback.h", "FMAdaptivePlaybackBridge.swift", "FMPlaybackQualityDisplay.m", "FMPlaybackQualityDisplay.h", "FMPlaybackQualityBridge.swift", "compile_extension.sh"]:
    manifest["source_sha256"][name] = hashlib.sha256((source_dir / name).read_bytes()).hexdigest()
for name in ["FMTrackMetadata.m", "FMTrackMetadata.h", "FMJSDownloadCoordinator.m", "FMJSDownloadCoordinator.h", "FMDownloadIntegration.m", "FMDownloadIntegration.h"]:
    manifest["source_sha256"][name] = hashlib.sha256((source_dir / name).read_bytes()).hexdigest()
for name in ["FMSettingsMigration.m", "FMSettingsMigration.h", "FMPlaybackSequence.m", "FMPlaybackSequence.h", "FMArtworkSelection.h", "FMArtworkSelection.m", "FMLXMCLocalStore.h", "FMLXMCLocalStore.m", "FMLXMCLocalProtocol.h", "FMLXMCLocalProtocol.m"]:
    manifest["source_sha256"][name] = hashlib.sha256((source_dir / name).read_bytes()).hexdigest()
for name in ["FMReplayCache.h", "FMReplayCache.m", "FMReplayMedia.h", "FMReplayMedia.m", "FMSongCacheAction.h", "FMSongCacheAction.m", "FMSongMenu.h", "FMSongMenu.m", "FMSongMenu.swift", "FMPlaylistEditor.h", "FMPlaylistEditor.m", "FMDownloadArtwork.h", "FMDownloadArtwork.m", "FMDownloadArtworkIntegration.h", "FMDownloadArtworkIntegration.m", "FMDownloadFiles.h", "FMPreferredDownloadStore.h", "FMPreferredDownloadStore.m", "FMRecordingMatch.h", "FMRecordingMatch.m", "FMTrackCover.h", "FMNativeDownloadCoverDisplay.h", "FMNativeDownloadCoverDisplay.m", "FMNativeDownloadCoverModel.swift", "FMLyricGesture.swift", "FMDownloadSort.swift"]:
    manifest["source_sha256"][name] = hashlib.sha256((source_dir / name).read_bytes()).hexdigest()
(output_dir / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print("DONE " + str(output_dir / "FMExtension.dylib"))
PY
