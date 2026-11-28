#!/bin/bash
# Run on the SAME already-booted, source-only smoke simulator before its teardown.
# Usage: bash test_interaction_ui.sh DEVICE_UDID NEW_OUTPUT_DIRECTORY
set -euo pipefail
[[ "$#" == 2 ]] || { echo "Usage: $0 DEVICE_UDID NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
device_id="$1"
output_dir="$2"
[[ "$(uname -s)" == Darwin ]] || { echo "Xcode and iOS Simulator required" >&2; exit 2; }
ui_arch="$(uname -m)"
[[ "$ui_arch" == arm64 || "$ui_arch" == x86_64 ]] || { echo "Unsupported UI test runner architecture: $ui_arch" >&2; exit 2; }
[[ ! -e "$output_dir" ]] || { echo "Use a new UI test artifact directory" >&2; exit 2; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
export FMX_INTERACTION_UI_OUTPUT="$output_dir"
stage="verify_preinstalled_self_authored_host"
finalize() {
  status=$?
  trap - EXIT
  python3 - "$stage" "$status" "$device_id" <<'PY'
import json,os,pathlib,sys
out=pathlib.Path(os.environ['FMX_INTERACTION_UI_OUTPUT'])
report={'passed':sys.argv[2]=='0','exit_code':int(sys.argv[2]),'stage':sys.argv[1],
        'device_id':sys.argv[3],'input':'XCTest real tap/doubleTap/drag',
        'target_bundle_id':'org.codex.fmx.smoke','original_ipa_used':False,
        'original_app_gesture_runtime_validated':False,
        'result_bundle':'interaction.xcresult','log':'xcodebuild.log'}
counts=out/'validated-execution-counts.json'
report['validated_execution_counts']=json.loads(counts.read_text()) if counts.exists() else None
report['passed']=report['passed'] and report['stage']=='completed' and report['validated_execution_counts'] is not None
(out/'interaction-ui.json').write_text(json.dumps(report,indent=2)+'\n')
PY
  if [[ "$status" == 0 ]]; then echo "DONE $output_dir/interaction-ui.json"; else echo "FAILED: UI test stage=$stage; $output_dir/interaction-ui.json" >&2; fi
  exit "$status"
}
trap finalize EXIT
xcrun simctl get_app_container "$device_id" org.codex.fmx.smoke app > "$output_dir/installed-self-authored-host.txt"
xcrun simctl terminate "$device_id" org.codex.fmx.smoke >/dev/null 2>&1 || true
stage="xctest_real_interaction"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/fmx-interaction-build.XXXXXX")"
# This UI-test-only project deliberately has no application target and does not
# replace the independently compiled host. XCUIApplication(bundleIdentifier:)
# launches the verified, preinstalled fixture bundle through public XCTest APIs.
xcodebuild test \
  -project "$source_dir/smoke/InteractionUITests/InteractionUITests.xcodeproj" \
  -scheme InteractionUITests -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "$build_dir" \
  -resultBundlePath "$output_dir/interaction.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  ONLY_ACTIVE_ARCH=YES "ARCHS=$ui_arch" CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$output_dir/xcodebuild.log"
stage="validate_five_actually_executed_ui_tests"
xcrun xcresulttool get test-results summary --path "$output_dir/interaction.xcresult" > "$output_dir/xcresult-summary.json"
python3 "$source_dir/verify_interaction_result.py" "$output_dir/xcresult-summary.json" > "$output_dir/validated-execution-counts.pending"
mv "$output_dir/validated-execution-counts.pending" "$output_dir/validated-execution-counts.json"
stage="completed"
