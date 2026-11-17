"""Bind v8 authored regression reports to the exact extension source build."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

SOURCES = ["FMSettingsMigration.h", "FMSettingsMigration.m", "FMSettingsMigrationTests.m",
           "FMSearchPreferences.h", "FMSearchPreferences.m", "FMSearchPreferencesTests.m",
           "FMExtensionProtocol.h", "FMExtensionProtocol.m", "FMExtensionProtocolTests.m", "intercept-contract-fixtures.json",
           "record_v8_validation.py"]
REPORTS = ["settings-migration-tests.json", "search-ranking-tests.json"]

def main():
    source = Path(__file__).resolve().parent
    inputs, output = map(Path, sys.argv[1:3])
    output.mkdir(parents=True, exist_ok=True)
    present = []
    for name in REPORTS:
        if (inputs / name).is_file():
            shutil.copyfile(inputs / name, output / name)
            present.append(name)
    manifest = {"scope": "Authored regression fixtures; original IPA and physical iPhone not used",
                "original_ipa_used": False, "test_platform": "macos",
                "source_sha256": {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in SOURCES},
                "report_sha256": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in present}}
    (output / "v8-build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    if present != REPORTS:
        raise SystemExit("Missing required v8 validation reports")

if __name__ == "__main__":
    main()
