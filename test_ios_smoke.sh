#!/bin/bash
# Source-only smoke. Never reads, uploads, installs or launches the user's IPA.
set -euo pipefail
if [[ "$#" -ge 1 ]]; then source_dir="$1"; else source_dir="$(dirname "$0")"; fi
source_dir="$(cd "$source_dir" && pwd -P)"
output_dir="${2:-$source_dir/smoke-artifact}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
export FMX_SMOKE_OUTPUT="$output_dir"
stage="environment"
device_id=""
work_dir=""

# Every simulator boot/diagnostic/cleanup command has its own deadline. PTY mode keeps
# bootstatus's progress visible even if the process later needs termination;
# redirected stdout was still empty after both previous 180-second timeouts.
# Only the subprocess group created here is terminated, never CoreSimulatorService.
bounded_sim_command() {
  python3 - "$@" <<'PY'
import errno,json,os,pathlib,selectors,signal,subprocess,sys,time
mode,limit,filename=sys.argv[1:4]; command=sys.argv[4:]
limit=float(limit); path=pathlib.Path(filename); started=time.monotonic()
result={'command':command,'timeout_seconds':limit,'timed_out':False,'mode':mode}
process=None; master=None; slave=None; selector=None
def stop_own_process():
    if process is None or process.poll() is not None: return
    try: os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError: return
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait(timeout=3)
try:
    with path.open('wb',buffering=0) as log:
        if mode=='pty':
            import pty
            master,slave=pty.openpty(); os.set_blocking(master,False)
            process=subprocess.Popen(command,stdout=slave,stderr=slave,start_new_session=True)
            os.close(slave); slave=None
            selector=selectors.DefaultSelector(); selector.register(master,selectors.EVENT_READ)
            heartbeat=started+30
            while True:
                now=time.monotonic()
                if now-started>=limit and process.poll() is None:
                    result['timed_out']=True; stop_own_process()
                if now>=heartbeat and process.poll() is None:
                    print(f'Waiting for simulator: {int(now-started)}s / {int(limit)}s',flush=True); heartbeat=now+30
                events=selector.select(timeout=0.5)
                received=False
                for key,_ in events:
                    try: data=os.read(master,65536)
                    except OSError as error:
                        if error.errno not in (errno.EIO,errno.EAGAIN): raise
                        data=b''
                    if data:
                        log.write(data); print(data.decode('utf-8','replace'),end='',flush=True); received=True
                if process.poll() is not None and not received: break
        elif mode=='raw':
            # Keep inventory JSON clean; metadata goes into a separate file.
            process=subprocess.Popen(command,stdout=log,stderr=subprocess.PIPE,start_new_session=True)
            try: _,error=process.communicate(timeout=limit)
            except subprocess.TimeoutExpired:
                result['timed_out']=True; stop_own_process(); _,error=process.communicate(timeout=3)
            if error: path.with_name(path.name+'.stderr').write_bytes(error)
        else: raise ValueError('Unsupported command output mode')
        result['returncode']=process.wait(timeout=3)
except Exception as error:
    result['error']=f'{type(error).__name__}: {error}'
    stop_own_process(); result['returncode']=1
finally:
    if selector is not None: selector.close()
    for descriptor in (master,slave):
        if descriptor is not None:
            try: os.close(descriptor)
            except OSError: pass
    result['elapsed_seconds']=round(time.monotonic()-started,3)
    path.with_name(path.name+'.meta.json').write_text(json.dumps(result,indent=2)+'\n')
if result['timed_out'] or result.get('returncode')!=0:
    print(f"Simulator command failed: {command!r}; see {path.name}.meta.json",file=sys.stderr)
    sys.exit(1)
PY
}

simulator_diagnostics() {
  local label="$1"
  bounded_sim_command raw 15 "$output_dir/$label-devices.json" xcrun simctl list devices --json || true
  bounded_sim_command raw 10 "$output_dir/$label-service.log" launchctl print "gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService" || true
  bounded_sim_command raw 10 "$output_dir/$label-processes.log" ps -axo pid,ppid,stat,etime,comm || true
  bounded_sim_command raw 10 "$output_dir/$label-disk.log" df -h "$output_dir" || true
  if [[ -n "$device_id" && "$label" != preboot ]]; then
    bounded_sim_command raw 15 "$output_dir/$label-system.log" /usr/bin/log show --last 2m --style compact --predicate "eventMessage CONTAINS '$device_id'" || true
    bounded_sim_command raw 15 "$output_dir/$label-springboard.log" xcrun simctl spawn "$device_id" log show --last 1m --style compact --predicate 'process == "SpringBoard" OR process == "backboardd"' || true
    bounded_sim_command raw 15 "$output_dir/$label-screenshot.log" xcrun simctl io "$device_id" screenshot --display=1 "$output_dir/$label.png" || true
  fi
}

finalize() {
  result=$?
  trap - EXIT
  if [[ -n "${container:-}" && -d "$container/Documents/smoke" ]]; then
    cp -R "$container/Documents/smoke/." "$output_dir/" || true
  fi
  if [[ -n "$device_id" ]]; then
    if [[ "$result" -ne 0 ]]; then
      python3 - "$device_id" "$output_dir/host-system.log" <<'PY'
import pathlib,subprocess,sys
try:
    with pathlib.Path(sys.argv[2]).open('w') as log:
        subprocess.run(['xcrun','simctl','spawn',sys.argv[1],'log','show','--last','3m','--style','compact','--predicate','process == "FreeMusic"'],stdout=log,stderr=subprocess.STDOUT,timeout=15)
except (OSError,subprocess.TimeoutExpired): pass
PY
    fi
    bounded_sim_command raw 15 "$output_dir/cleanup-screenshot.log" xcrun simctl io "$device_id" screenshot --display=1 "$output_dir/simulator-final.png" || true
    bounded_sim_command raw 10 "$output_dir/cleanup-terminate.log" xcrun simctl terminate "$device_id" org.codex.fmx.smoke || true
    bounded_sim_command raw 30 "$output_dir/cleanup-shutdown.log" xcrun simctl shutdown "$device_id" || true
    bounded_sim_command raw 15 "$output_dir/cleanup-delete.log" xcrun simctl delete "$device_id" || true
  fi
  if [[ "$result" -ne 0 ]]; then
    python3 - "$stage" "$result" <<'PY'
import json, os, pathlib, sys
root=pathlib.Path(os.environ['FMX_SMOKE_OUTPUT'])
p=root/'smoke.json'
if not p.exists():
    p.write_text(json.dumps({'complete':True,'passed':False,'failed_stage':sys.argv[1],'exit_code':int(sys.argv[2]),'original-app-launch-validated':False,'lock-screen-system-display-validated':False},indent=2)+'\n')
PY
    echo "FAILED: iOS smoke stage=$stage; report=$output_dir/smoke.json" >&2
  else
    echo "DONE $output_dir/smoke.json"
  fi
  exit "$result"
}
trap finalize EXIT
[[ "$(uname -s)" == Darwin ]] || { echo "macOS/Xcode Simulator required" >&2; exit 2; }
# Use the workflow's selected SDK; never silently fall back to the runner's old
# default Xcode. Current cloud workflow sets Xcode_27.2 explicitly.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
fi
[[ -d "$DEVELOPER_DIR" ]] || { echo "Configured DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2; exit 2; }
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
python3 - "$sdk_version" <<'PY'
import sys
assert int(sys.argv[1].split('.')[0])>=26, 'iOS Simulator SDK >=26 is required'
PY
for name in FMExtension.m FMExtensionProtocol.m FMQishuiSearch.m FMQishuiSearch.h FMSettingsEntry.m FMSettingsEntry.h FMSearchPreferences.m FMSearchPreferences.h LXSourceRuntime.m FMLockScreen.m LXBootstrap.js smoke/Host.m smoke/SettingsFixture.swift; do
  [[ -f "$source_dir/$name" ]] || { echo "Missing source: $name" >&2; exit 2; }
done
[[ ! -e "$output_dir/smoke.json" ]] || { echo "Use a new artifact directory" >&2; exit 2; }
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fmx-ios-smoke.XXXXXX")"
app_dir="$work_dir/Smoke.app"
mkdir -p "$app_dir/Frameworks"
arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unsupported runner architecture: $arch" >&2; exit 2; }

stage="compile_simulator_dylib"
bash "$source_dir/compile_extension.sh" "$source_dir" iphonesimulator "${arch}-apple-ios26.0-simulator" "$app_dir/Frameworks/FMExtension.dylib" simulator 2>&1 | tee "$output_dir/compile-dylib.log"

stage="compile_self_authored_host"
xcrun --sdk iphonesimulator clang \
  -target "${arch}-apple-ios26.0-simulator" -isysroot "$sdk_path" \
  -fobjc-arc -fblocks -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -Werror=implicit-function-declaration -I "$source_dir" \
  -framework Foundation -framework UIKit -framework MediaPlayer \
  -framework AVFoundation -framework CoreMedia -framework CoreGraphics \
  "$source_dir/smoke/Host.m" -o "$app_dir/FreeMusic" 2>&1 | tee "$output_dir/compile-host.log"

stage="compile_self_authored_swiftui_fixture"
xcrun --sdk iphonesimulator swiftc \
  -target "${arch}-apple-ios26.0-simulator" -sdk "$sdk_path" \
  -swift-version 5 -emit-library -parse-as-library -module-name SmokeSettingsFixture \
  -framework SwiftUI -framework UIKit -framework Foundation \
  -Xlinker -install_name -Xlinker '@executable_path/Frameworks/SmokeSettingsFixture.dylib' \
  "$source_dir/smoke/SettingsFixture.swift" "$source_dir/smoke/LXMCFixture.swift" "$source_dir/smoke/InteractionFixture.swift" "$source_dir/smoke/NavigationFixture.swift" \
  "$source_dir/smoke/PlaybackCacheFixture.swift" "$source_dir/smoke/AdaptivePlaybackFixture.swift" "$source_dir/smoke/PlaybackQualityFixture.swift" \
  -o "$app_dir/Frameworks/SmokeSettingsFixture.dylib" 2>&1 | tee "$output_dir/compile-swiftui-fixture.log"
cp "$source_dir/LXBootstrap.js" "$app_dir/LXBootstrap.js"
python3 - "$app_dir" "$sdk_version" "$source_dir" "$output_dir" <<'PY'
import hashlib,json,pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); source=pathlib.Path(sys.argv[3]); out=pathlib.Path(sys.argv[4])
info={'CFBundleIdentifier':'org.codex.fmx.smoke','CFBundleExecutable':'FreeMusic','CFBundleName':'LX Extension Smoke','CFBundleDisplayName':'LX Extension Smoke','CFBundlePackageType':'APPL','CFBundleShortVersionString':'4.2.7','CFBundleVersion':'1','MinimumOSVersion':'26.0','UIDeviceFamily':[1],'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Smoke','UISceneDelegateClassName':'SmokeSceneDelegate'}]}}}
# Permit only the authored loopback HTTP media fixture; production Info.plist is untouched.
info['NSAppTransportSecurity']={'NSAllowsLocalNetworking':True}
with (app/'Info.plist').open('wb') as f: plistlib.dump(info,f)
manifest={'sdk':sys.argv[2],'developer_dir':__import__('os').environ['DEVELOPER_DIR'],'original_ipa_used':False,'test_macro':'FMX_LOCKSCREEN_TESTING','source_sha256':{name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ['FMExtension.m','FMExtensionProtocol.m','FMQishuiSearch.m','FMQishuiSearch.h','FMSettingsEntry.m','FMSettingsEntry.h','FMSearchPreferences.m','FMSearchPreferences.h','LXSourceRuntime.m','LXBootstrap.js','FMLockScreen.m','smoke/Host.m','smoke/SettingsFixture.swift','FMListeningHistory.m','FMListeningHistory.h','FMInsights.m','FMInsights.h','FMInteraction.m','FMInteraction.h','FMLXMC.m','FMLXMC.h']}}
for name in ['FMLXMCUI.m','FMLXMCUI.h','smoke/LXMCFixture.swift','FMNavigation.m','FMNavigation.h','smoke/NavigationFixture.swift','smoke/InteractionFixture.swift','smoke/V3NavigationTests.inc','FMListeningCapture.m','FMListeningCapture.h']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
for name in ['smoke/V3InteractionTests.inc','test_interaction_ui.sh','smoke/InteractionUITests/InteractionUITests.swift','smoke/InteractionUITests/InteractionUITests.xcodeproj/project.pbxproj','smoke/InteractionUITests/InteractionUITests.xcodeproj/xcshareddata/xcschemes/InteractionUITests.xcscheme']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
for name in ['smoke/V3ListeningCaptureTests.inc','verify_interaction_result.py','test_verify_interaction_result.py']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
for name in ['FMPlaybackCache.m','FMPlaybackCache.h','smoke/PlaybackCacheFixture.swift','smoke/V5PlaybackCacheTests.inc']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
for name in ['FMQualityResolver.m','FMQualityResolver.h','FMAdaptivePlayback.m','FMAdaptivePlayback.h','FMAdaptivePlaybackBridge.swift','FMPlaybackQualityDisplay.m','FMPlaybackQualityDisplay.h','FMPlaybackQualityBridge.swift','compile_extension.sh','smoke/AdaptivePlaybackFixture.swift','smoke/V6AdaptivePlaybackTests.inc','smoke/V6QualityRoutingTests.inc','smoke/PlaybackQualityFixture.swift','smoke/V6PlaybackQualityTests.inc']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
manifest['test_macros']=['FMX_LOCKSCREEN_TESTING','FMX_LISTENING_CAPTURE_TESTING','FMX_PLAYBACK_CACHE_TESTING','FMX_ADAPTIVE_PLAYBACK_TESTING','FMX_PLAYBACK_QUALITY_TESTING']
for name in ['FMTrackMetadata.m','FMTrackMetadata.h','FMJSDownloadCoordinator.m','FMJSDownloadCoordinator.h','FMDownloadIntegration.m','FMDownloadIntegration.h']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
for name in ['FMSettingsMigration.m','FMSettingsMigration.h','FMPlaybackSequence.m','FMPlaybackSequence.h','smoke/V8PlaybackSequenceTests.inc','smoke/V8SourceSelectionTests.inc','FMArtworkSelection.h','FMArtworkSelection.m']:
    manifest['source_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
(out/'build.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
codesign --force --sign - "$app_dir/Frameworks/FMExtension.dylib" >"$output_dir/sign.log" 2>&1
codesign --force --sign - "$app_dir/Frameworks/SmokeSettingsFixture.dylib" >>"$output_dir/sign.log" 2>&1
codesign --force --sign - "$app_dir" >>"$output_dir/sign.log" 2>&1

stage="select_available_ios_simulator"
bounded_sim_command raw 60 "$output_dir/simctl-inventory.json" xcrun simctl list --json
python3 - "$output_dir/simctl-inventory.json" "$work_dir/selection.txt" "$output_dir/simulator.json" <<'PY'
import json,pathlib,re,sys
data=json.loads(pathlib.Path(sys.argv[1]).read_text())
def version(s): return tuple(int(v) for v in re.findall(r'\d+',s))
# Pin the ordinary-phone UI baseline. A version-only sort can choose the
# iPhone19-4/Duo-only 27.2 runtime, whose geometry is outside this task's scope.
required_runtime='com.apple.CoreSimulator.SimRuntime.iOS-27-2'
runtime=next((r for r in data['runtimes'] if r.get('isAvailable') and r.get('identifier')==required_runtime and r.get('version')=='27.2'),None)
assert runtime, 'Required generic iOS 27.2 runtime is unavailable; no Duo/fold-specific or older runtime substitution is allowed'
types={d['identifier']:d for d in data['devicetypes']}
supported={d.get('identifier') if isinstance(d,dict) else d for d in runtime.get('supportedDeviceTypes',[])}
assert supported, 'Generic iOS 27.2 does not advertise supported device types; compatibility cannot be established'
preferred_phones=['iPhone 18 Pro','iPhone 17 Pro','iPhone 16 Pro','iPhone 18 Pro Max','iPhone 17 Pro Max','iPhone 16 Pro Max','iPhone 17','iPhone 16','iPhone 15 Pro','iPhone 15 Pro Max','iPhone 15']
encoded=sum(v << shift for v,shift in zip((version(runtime['version'])+(0,0))[:3],(16,8,0)))
candidates={d['name']:d for d in data['devicetypes'] if d['identifier'] in supported and d['name'] in preferred_phones and d.get('minRuntimeVersion',0)<=encoded<=d.get('maxRuntimeVersion',0xffffffff)}
selected=next((candidates[name] for name in preferred_phones if name in candidates),None)
assert selected, 'Generic iOS 27.2 has no supported ordinary iPhone baseline; Duo/foldable devices are not accepted'
chosen=selected['identifier']
pathlib.Path(sys.argv[2]).write_text(runtime['identifier']+'\n'+chosen+'\n')
pathlib.Path(sys.argv[3]).write_text(json.dumps({'runtime':runtime,'device_type':selected,'selection_policy':{'required_runtime':required_runtime,'allowed_device_names_in_preference_order':preferred_phones,'selected_preference_index':preferred_phones.index(selected['name']),'specialized_or_foldable_fallback_allowed':False}},indent=2)+'\n')
PY
runtime_id="$(sed -n '1p' "$work_dir/selection.txt")"
device_type="$(sed -n '2p' "$work_dir/selection.txt")"
device_name="FMX Smoke $$"
bounded_sim_command raw 60 "$output_dir/device-create.log" xcrun simctl create "$device_name" "$device_type" "$runtime_id"
created_id="$(tr -d '\r\n' < "$output_dir/device-create.log")"
[[ "$created_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { echo "Invalid newly created simulator identifier" >&2; exit 2; }
device_id="$created_id"
python3 - "$device_id" "$device_name" "$runtime_id" "$device_type" "$output_dir/created-device.json" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[5]).write_text(json.dumps(dict(udid=sys.argv[1],name=sys.argv[2],runtime=sys.argv[3],device_type=sys.argv[4],created_for_this_run=True),indent=2)+'\n')
PY
stage="boot_simulator"
simulator_diagnostics preboot
boot_ready=false
if bounded_sim_command pty 60 "$output_dir/boot-request.log" xcrun simctl boot "$device_id" &&
   bounded_sim_command pty 360 "$output_dir/boot.log" xcrun simctl bootstatus "$device_id" -b; then
  boot_ready=true
else
  # One recovery only, and only the exact fresh device created above. Do not
  # kill services, shutdown all devices, erase a device, or select another OS.
  simulator_diagnostics boot-first-failure
  stage="recover_own_simulator_once"
  if bounded_sim_command raw 30 "$output_dir/recovery-shutdown.log" xcrun simctl shutdown "$device_id" &&
     bounded_sim_command pty 60 "$output_dir/recovery-boot-request.log" xcrun simctl boot "$device_id" &&
     bounded_sim_command pty 180 "$output_dir/boot-recovery.log" xcrun simctl bootstatus "$device_id" -b; then
    boot_ready=true
  else
    simulator_diagnostics boot-final-failure
  fi
fi
[[ "$boot_ready" == true ]] || { echo "Self-created simulator failed both bounded boot attempts; no application/UI tests were skipped or passed" >&2; exit 1; }
# Bootstatus above is the readiness gate. Inventory is diagnostic only: a slow
# list operation must not turn an already successful boot into a test failure.
bounded_sim_command raw 15 "$output_dir/boot-ready-devices.json" xcrun simctl list devices --json || true
bounded_sim_command raw 15 "$output_dir/status-bar.log" xcrun simctl status_bar "$device_id" override --time '9:41' --batteryState charged --batteryLevel 100 || true
stage="install_self_authored_host"
xcrun simctl install "$device_id" "$app_dir"
container="$(xcrun simctl get_app_container "$device_id" org.codex.fmx.smoke data)"
export FMX_SMOKE_CONTAINER="$container"

run_phase() {
  phase="$1"
  shift
  xcrun simctl launch --terminate-running-process "$device_id" org.codex.fmx.smoke "$@" > "$output_dir/launch-$phase.log" 2>&1
  python3 - "$phase" <<'PY'
import os,pathlib,time,sys,json
phase=sys.argv[1]; root=pathlib.Path(os.environ['FMX_SMOKE_CONTAINER'])/'Documents'/'smoke'
target=root/('smoke-'+phase+'.json'); deadline=time.monotonic()+240
while time.monotonic()<deadline:
    if target.exists():
        try:
            result=json.loads(target.read_text())
            if result.get('complete'): break
        except (OSError,json.JSONDecodeError): pass
    time.sleep(1)
else: raise RuntimeError('Host '+phase+' phase did not finish in 240 seconds; see progress report')
PY
  cp -R "$container/Documents/smoke/." "$output_dir/"
  xcrun simctl io "$device_id" screenshot --display=1 "$output_dir/simulator-$phase.png" >/dev/null
}
stage="natural_host_smoke"
run_phase natural
needs_forced="$(python3 - "$output_dir/smoke-natural.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]));print('yes' if data.get('requires-forced-coordinator-pass') else 'no')
PY
)"
if [[ "$needs_forced" == yes ]]; then
  stage="forced_coordinator_fixture"
  run_phase forced --force-artwork-capability
fi
stage="validate_native_before_ui"
# Report the concrete assertion before expensive UI-test compilation, and
# stop early on native failures. Successful runs still require all UI tests.
python3 - "$output_dir" <<'PY'
import json,pathlib,sys
out=pathlib.Path(sys.argv[1]); natural=json.loads((out/'smoke-natural.json').read_text())
phases=[natural]
if natural.get('requires-forced-coordinator-pass'):
    phases.append(json.loads((out/'smoke-forced.json').read_text()))
for phase in phases:
    rows=phase.get('tests',[])
    print(json.dumps({'phase':phase.get('phase'),'total':len(rows),'passed':sum(bool(r.get('passed')) for r in rows),'failed':[r for r in rows if not r.get('passed')],'adaptive':[r for r in rows if r.get('name','').startswith('v6_')]},ensure_ascii=False),flush=True)
if not all(p.get('complete') and p.get('passed') for p in phases):
    raise SystemExit('Native smoke assertion failed; UI tests not started; inspect smoke-natural.json')
PY
stage="real_ui_interaction_tests"
interaction_status=0
bash "$source_dir/test_interaction_ui.sh" "$device_id" "$output_dir/interaction-ui" || interaction_status=$?
stage="validate_smoke_report"
python3 - "$output_dir" <<'PY'
import json,pathlib,sys
out=pathlib.Path(sys.argv[1]);natural=json.loads((out/'smoke-natural.json').read_text());forced=None
if natural.get('requires-forced-coordinator-pass'):
    forced=json.loads((out/'smoke-forced.json').read_text())
interaction_path=out/'interaction-ui/interaction-ui.json'
interaction=json.loads(interaction_path.read_text()) if interaction_path.exists() else {'passed':False,'error':'UI test report missing'}
passed=bool(natural.get('passed')) and (not natural.get('requires-forced-coordinator-pass') or bool(forced and forced.get('passed'))) and bool(interaction.get('passed'))
report={'complete':True,'passed':passed,'real-supported-animated-artwork-keys':natural.get('real-supported-animated-artwork-keys',[]),'forced-capability':forced is not None,'natural':natural,'forced':forced,'original-app-launch-validated':False,'lock-screen-system-display-validated':False,'scope':'Independent Simulator host: native extension UI, fixture-only source parsing, generated artwork file checks, local Now Playing coordinator. Does not establish original IPA startup or real-device Lock Screen behavior.'}
report['interaction_ui']=interaction
(out/'smoke.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
assert passed,'Native smoke assertions failed; inspect smoke.json'
PY
