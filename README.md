# FreeMusic 4.2.7 extension — v3 incremental update

Source-only build for a user-authorized modification of FreeMusic-Folia 4.2.7.
This repository does not contain the original application, signing identities,
provisioning profiles, cookies, third-party music scripts, or music files.

The extension places 音源与扩展 inside the verified original Settings page and
removes the global floating source button. Home search aggregation combines
NetEase, Kugou, QQ and Qishui, retaining each result's real platform and ID.
The v2 migration enables aggregation once and preserves subsequent opt-out.
Turning aggregation off restores the saved native platform selection.
Settings identification requires the original title and independent source and
preference/storage section evidence. If SwiftUI does not expose those labels,
bounded on-device Vision recognition reads the rendered settings list in memory;
no screenshots or recognized text are saved or sent to a service.

Qishui uses the original application's public client configuration, read locally
from the exact version/UUID-checked executable, and the same normal catalogue
token/search endpoints. No configuration values or tokens are in this repository.
Tokens stay in memory, pagination follows returned cursors, and a failed source
does not discard successful results. Qishui connection status appears in Settings.
Qishui playback retains the host's own track-detail and playback flow.

The JavaScriptCore adapter implements a documented subset of the LX custom-source
API. NetEase and QQ ID-only musicUrl scripts can be selected.
Kugou's exact native hash request can use scripts advertising standard 128k
quality; failures retain the original fallback path. QQ encrypted playback
remains original behavior.
No membership, authentication, DRM or account checks are modified.

This is an experimental binary extension, not recovered original source code.
Compilation/fixture success does not prove that a re-signed IPA launches or that
network interception works on an iPhone. Device validation is required.

## V3 additions

- Version-locked binary patches connect the existing preview lyric row to the
  native seek closure and enable its hit testing. The parent expansion gesture
  becomes a double tap; the full lyric view's close gesture remains unchanged.
- The Discover tab is hidden without changing native tab identities. The two
  optional profile cover collections are removed through their existing empty
  branches. Startup selects Library and attempts its unique Favorites link once,
  confirming the resulting navigation before reporting success.
- Search results use native on-drag keyboard dismissal. Existing interactive
  policies, horizontal lists and unrelated modal text entry are preserved.
- Monthly/yearly listening insights use measured AVPlayer progress, bound to the
  original executable's UUID and inspected observer/activity call sites. Records
  stay on the device; old cumulative history is not backfilled into invented dates.
  Music types use provided genre or explicit title tags, with unknown types shown
  as unknown. A user can disable or clear these local records.
- The native external-playlist alert accepts gzip/plain LX .lxmc playlists through
  a file picker and a process-local, single-use parser bridge. Supported platform
  identities are preserved. The original app still creates the playlist through
  its normal authenticated backend; unsupported entries are disclosed before import.

Package v3 with `--v3-changes`. The original IPA must remain local. Local original
binary tests check the patch sites, register/stack behavior and non-overlap;
Foundation tests and the self-authored Simulator fixtures check the new modules.
The UI tests must actually execute the expected cases; a zero-test run fails.
These checks do not substitute for testing the re-signed original on an iPhone.

## Build

GitHub Actions runs on macOS, tests the runtime, four-source protocol, native
search preferences and Qishui pagination with local fixtures, and compiles an
arm64 iOS 17+ dylib. A synthetic UIKit/SwiftUI Simulator host checks Settings-only
entry in a native List, Home search, AppStorage platform changes and artwork generation.
Download the FMExtension-arm64 artifact.
The original IPA is processed locally with `package_extension.py`; pass the
original file, compiled dylib, bootstrap and a new output filename. The tool
locks the original IPA/binary hashes, preserves segment layout, removes obsolete
main-app signatures, and refuses to overwrite original inputs.

The resulting IPA needs full re-signing of nested code and the main application
with valid signing inputs. Keep the bundle identifier and provisioning/entitlement
identifiers consistent. No certificate or profile is fabricated or reused.

## Limits

- JS APIs: musicUrl, Promise, HTTP text/JSON/form, cancellation, timers, buffer
  UTF-8/base64/hex, MD5, AES-128-CBC/ECB and randomBytes.
- RSA, zlib, multipart and binary HTTP are not implemented. Rich QQ/Kugou metadata
  is unavailable in the host search results. Not every LX source is compatible.
- Qishui search and playback use the host's native service flow; importing an LX
  script does not add Qishui JS support. The verified configuration loader is
  intentionally restricted to this original 4.2.7 executable.
- Only trusted scripts should be enabled. API isolation does not stop infinite
  JavaScript loops or cap heap memory. A timeout can abandon the native operation
  but cannot forcibly stop JavaScriptCore execution through its public API.
- iOS 26+ dynamic artwork uses the public MediaPlayer API and creates a gentle
  six-second motion loop from the current cover locally, on demand. It uses a
  bounded cache, retains active files, cancels stale work and falls back to static
  artwork for low power, reduced motion, thermal limits or unsupported systems.
  It does not obtain publisher-supplied animated album art.
- The host's lock-screen launch issue is unverified. Original routing already
  exists; signing identity must be consistent and checked on the real device.
  The optional 1000-to-1600 image decode patch is off by default; normal providers
  still have their own smaller image limits.
- POST body streams are buffered with a 64 KiB limit before delegation. Sources
  outside the selected JS contract retain their complete native request/response.

`verify_signing_identity.py` is an offline consistency check for the re-signed
IPA. It does not prove cryptographic signature validity or successful device
installation. The simulator harness uses a synthetic host and fixtures only,
and does not constitute an original-app or lock-screen device test.

Protocol and lifecycle evidence is recorded separately in the local work folder.
