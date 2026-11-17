"""Record source-only v7 test evidence alongside the simulator artifact."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

SOURCES = [
    "LXBootstrap.js", "LXSourceRuntime.h", "LXSourceRuntime.m", "LXRuntimeTests.m",
    "test_lx_bootstrap.cjs", "test_lx_runtime_macos.sh", "LXQualityRuntimeTests.m",
    "FMExtension.m", "FMExtensionProtocol.h", "FMExtensionProtocol.m", "FMExtensionProtocolTests.m",
    "FMLXMC.h", "FMLXMC.m", "FMLXMCTests.m",
    "FMTrackMetadata.h", "FMTrackMetadata.m", "FMTrackMetadataTests.m",
    "FMQualityResolver.h", "FMQualityResolver.m", "FMQualityResolverTests.m",
    "FMJSDownloadCoordinator.h", "FMJSDownloadCoordinator.m", "FMJSDownloadTests.m",
    "FMDownloadIntegration.h", "FMDownloadIntegration.m", "FMDownloadIntegrationTests.m",
    "FMDownloadTestFixtures.inc", "test_native_download_macos.sh", "record_v7_validation.py",
    "native_format_patch.py", "test_native_format_patch.py",
    "FMNativeDownloadFormatTests.m", "test_native_download_format_macos.sh",
]
REPORTS = ["download-coordinator-tests.json", "native-download-tests.json", "download-format-tests.json"]

def main():
    source = Path(__file__).resolve().parent
    inputs, output = map(Path, sys.argv[1:3])
    output.mkdir(parents=True, exist_ok=True)
    present = []
    for name in REPORTS:
        if (inputs / name).is_file():
            shutil.copyfile(inputs / name, output / name)
            present.append(name)
    manifest = {
        "scope": "Authored macOS real HTTP fixtures; original app runtime and physical iPhone are not tested",
        "original_ipa_used": False, "test_platform": "macos",
        "source_sha256": {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in SOURCES},
        "report_sha256": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in present},
    }
    (output / "v7-build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if present != REPORTS:
        raise SystemExit("Missing required v7 download validation reports")

if __name__ == "__main__":
    main()
