# FreeMusic 4.2.9 extension — playback, downloads and library

Source-only build for a user-authorized modification of FreeMusic-Folia 4.2.9, build 4381.
This repository does not contain the original application, signing identities,
provisioning profiles, cookies, third-party music scripts, or music files.

On FreeMusic 4.2.9 (4381), JS playback can reuse a verified local audio file
or a previously resolved address for the same source, platform, track and
quality. After an address fails, the player retries the resolver. Changing the
selected script starts a new cache generation. Local Downloads is the first
Library row, followed by Recent Plays. Library playlist ordering,
names, track ordering and removals are stored on the device. Dragging up or down on a lyric scrolls the lines. A downward drag starting
beside the visible words collapses the player while audio continues. When
line positions are unavailable, either outer margin supports the same gesture.
Tapping a timed line seeks to its start.

Previously downloaded tracks with missing artwork can recover it from an
embedded picture, known artwork, or public album metadata for the exact
NetEase song ID. Repairs respect the app’s three native artwork locations and
refresh the matching row in Local Downloads. The source settings show how many
NetEase downloads have a usable cover, are still pending, or need attention.

The extension places 音源与扩展 inside the verified original Settings page and
removes the global floating source button. Home search aggregation combines
NetEase, Kugou, QQ and Qishui, retaining each result's real platform and ID.
The versioned migration initializes missing preferences and preserves explicit opt-out.
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

The JavaScriptCore adapter implements LX mobile's musicUrl host contract and the
documented networking, buffer and crypto helpers used by supported scripts.
NetEase and QQ musicUrl scripts can be selected. Track metadata already received
from search/import is normalized to the LX fields without inventing unavailable
media IDs or quality hashes. Missing platform data can still limit a script.
Kugou's exact native hash request can use scripts advertising standard 128k
quality. Enabled JS routes report exhausted candidates rather than silently falling back to the native source. When JS is enabled for QQ, a premium/QMC request can receive a plain JS audio URL with null QMC metadata; the original response decoder passes the plain URL through without invoking its encrypted-media branch. No decryption or authorization checks are altered.
No membership, authentication, DRM or account checks are modified.

This is an experimental binary extension, not recovered original source code.
Compilation/fixture success does not prove that a re-signed IPA launches or that
network interception works on an iPhone. Device validation is required.

This branch targets build 4381. Use the original 4.2.9 archive and the cumulative
v8 packaging flags plus `--quiet-update`. This option suppresses the optional
upgrade sheet on launch. A user-initiated check in Settings can still show it.

## V7 additions

- Align AES-ECB padding and raw RSA with LX mobile. Support binary request/response bytes, multipart form bodies and additional buffer/console behavior. This is a JavaScriptCore implementation, not the original Android QuickJS native bridge; unsupported platform/source capabilities remain explicit.
- Playback and native manual downloads use independent highest-first JS resolver sessions. Download retries must not consume a playing item's remaining quality candidates or reuse another source generation.
- Each quality attempt is capped at 20 seconds, matching [LX mobile's request deadline](https://github.com/lyswhut/lx-music-mobile/blob/0669d1b6d419967822ff52ec06e50b9613bfd136/src/core/init/userApi/index.ts#L52-L57). Source initialization counts toward that limit. The existing 35-second parse-chain budget and any shorter caller deadline still apply. After an accepted URL fails during actual media I/O, the remaining candidates receive a fresh bounded parse call. Quality indices and failed-URL deduplication never reset.
- Each production musicUrl attempt owns an isolated JS runtime. Completion, timeout, cancellation and source changes retire its network tasks and timers without cancelling another playback/download attempt. This does not preempt synchronous JavaScript loops.
- Native manual download integration is restricted to the exact verified CacheManager and JS-owned URLs. Existing task identities, original download UI and original completion/save/list-registration callbacks are retained. Unowned downloads remain native.
- Real downloaded files are checked before success; unsuccessful candidates proceed to lower supported qualities. Cancellation/source changes retire temporary data and stale callbacks. Already saved files are preserved.
- The verified native download-save boundary preserves the actual audio container extension. It does not transcode media or disguise M4A/FLAC as MP3. The original offline lookup and library registration must remain consistent with the saved filename.
- Synthetic loopback and independent host tests never use third-party sources, credentials or original IPA code in CI. Packaging still requires full signing and testing on the user's device.

## V6 additions

- Enabled JS takes priority on the supported NetEase/QQ/Kugou parsing routes, including QQ quality selections that previously stayed native. The source and adapter's common quality list is tried highest first (24-bit FLAC, FLAC, 320k, 128k); Kugou remains 128k-only with the available hash contract.
- Each candidate is attempted once. Parsing errors/timeouts advance to the next quality within a shared time budget. Source transitions, cancellation and stale callbacks cannot adopt a different song/source's result. A returned URL is a candidate, not evidence of complete playback or encoded quality.
- Two exact-build native setup/failure bridges retain the same session after a URL is delivered. A current item's actual playback failure tries the remaining qualities and calls the original player setup to rebind native observers. Unmanaged items retain their original behavior.
- The existing small player quality badge uses measured AVAsset format information. Requested quality and filename extensions are not treated as measured quality; unavailable information is shown as unknown. This does not verify the provenance of a supposedly lossless master.
- A metadata deadline cancels that request without automatically disabling a responsive JS source. A blocked JavaScript queue is still discarded; public JavaScriptCore APIs cannot forcibly kill an infinite loop.

Package v7 with `--v3-changes --player-left-swipe --playback-cache --adaptive-playback --native-download-format` (v6 omits the final flag). Cloud builds contain only the extension and authored fixtures. Simulator fixtures and instruction emulation do not constitute an on-device test of the original FreeMusic IPA.

## V4 additions

- Listening insights remains in Settings → 音源与扩展 → 听歌画像. The original
  profile Settings gear is preserved; the extra profile toolbar button is removed.
- The original player top handle/title gestures also accept a left swipe, using
  the original SwiftUI dismissal/binding. Original downward dismissal is retained.
  Lyrics and playback/volume controls do not gain a full-screen competing gesture.
- Music URL resolution allows the source's normal main/backup request sequence;
  the host's shorter request timeout still takes precedence. Settings reports
  whether JS actually returned a URL, without recording song IDs or credentials.
  This does not establish that a server returned full audio rather than a preview.

Package v4 with `--v3-changes --player-left-swipe`. Original IPA tests run locally;
the cloud receives only extension and anonymous test source.

## V3 additions

- Version-locked binary patches connect the existing preview lyric row to the
  native seek closure and enable its hit testing. The parent expansion gesture
  becomes a double tap; the full lyric view's close gesture remains unchanged.
- The Discover tab is hidden without changing native tab identities. The two
  optional profile cover collections are removed through their existing empty
  branches. A cold launch opens the Library root, where all playlists are
  visible. Favorites opens when the user selects it. Returning from the
  background preserves the current page.
- Search results use native on-drag keyboard dismissal. Existing interactive
  policies, horizontal lists and unrelated modal text entry are preserved.
- Monthly/yearly listening insights use measured AVPlayer progress, bound to the
  original executable's UUID and inspected observer/activity call sites. Records
  stay on the device; old cumulative history is not backfilled into invented dates.
  Music types use provided genre or explicit title tags, with unknown types shown
  as unknown. A user can disable or clear these local records.
- The native external-playlist alert accepts gzip/plain LX .lxmc playlists through
  a file picker and a process-local, single-use parser bridge. Supported platform
  identities are preserved. V3–V7 used the original authenticated backend;
  V8 newly imported LXMC playlists are device-local, as described below.
  Unsupported entries are disclosed before import.

## V8 reliability additions

- Aggregate Home search ranks each fetched page by title and artist relevance.
  Exact combinations come first; live, cover and other versions retain their
  original names and platform IDs. Pagination and per-source failure isolation
  remain native. It does not claim to rank results which were never fetched.
- The verified native selection-UUID commit retires old adaptive playback and
  actual-quality probes immediately, including while the next URL is pending.
  Existing native audio and lyric UUID guards remain. The narrow missing-cover
  bridge clears the old URL identity and retained image using the native Swift
  and Objective-C ownership rules, so late artwork cannot fill a coverless track.
- Original early preload, shuffled queue and cached-player adoption remain.
  A ready, playing current item with at most ten seconds left reconciles missing
  next-track preload once. Successful entries are retained; an already failed
  candidate can retry. The next button and preload use the same queue candidate.
- New LXMC imports use device-local transactional storage and the original
  Library playlist screens. A duplicate source offers explicit replace, copy or
  cancel. A complete validated snapshot is committed atomically; failed writes
  preserve the old playlist. Existing cloud playlists are not migrated, deleted
  or automatically replaced. Local imports are not synced to other devices.
- Extension preferences use a versioned migration with a recovery journal.
  Explicit opt-outs, saved JS choice and unrelated native preferences survive.
  Runtime retirement no longer erases the saved choice; only explicit disable
  or deletion does. Failed/interrupted initialization pauses automatic retry,
  retaining the previous choice for a deliberate retry.

V8 packaging adds `--playback-sequence --artwork-selection` to the cumulative
V7 flags. Exact-build checks, actual ARM64 instruction execution, macOS fixtures
and an independent iPhone Simulator host verify the authored changes. Original
IPA execution, signing validity and physical-device behavior remain separate
checks; a successful cloud build is not reported as an iPhone test.

### Upgrading the supplied V7 IPA

For `FreeMusic_4.2.7_v7_JS-download_20261117.unsigned.needs-resigning.ipa`,
use `upgrade_v7_ipa.py` with a successful V8 GitHub Actions artifact:

```bash
python3 upgrade_v7_ipa.py /path/to/FreeMusic_4.2.7_v7_JS-download_20261117.unsigned.needs-resigning.ipa \
  --dylib /path/to/artifact/FMExtension.dylib \
  --bootstrap /path/to/artifact/LXBootstrap.js \
  --build-manifest /path/to/artifact/build-manifest.json \
  --output /path/to/FreeMusic_4.2.7_v8.unsigned.needs-resigning.ipa
```

The upgrade locks the uploaded V7 archive, executable, old extension and
bootstrap by SHA-256. It checks the downloaded build's hashes, source provenance
and V8 exports, then adds only the selection/artwork bridges and replaces the
extension. Existing V7 download, cache, navigation and swipe patches remain.
All other archive resources, including the bundle identifier, stay byte-identical.
It refuses modified input, a second upgrade, a mismatched artifact or an existing
output. GitHub compiles and tests the extension; IPA assembly runs locally.

`python3 test_v7_upgrade.py --ipa /path/to/the/V7.ipa -v` verifies the real input
locally, including all unchanged resources and preservation of earlier patches.
Without `--ipa`, CI uses authored structural fixtures only. Temporary test
libraries are never delivered. Fully re-sign the result before installation;
use the same app identity and update in place to retain on-device preferences.

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

- JS source transitions invalidate native pre-resolved URLs and waiting players,
  and give both native in-memory cache-key builders a new generation suffix.
  Late results can retain their old keys but cannot become hits in a new generation.
  Previously JS-managed platforms skip automatic disk music caches because those
  native files do not record their source identity. Explicit downloads remain
  eligible, and no music files are deleted. This can cause extra network parsing
  on those platforms, including after JS is disabled.

- JS APIs: musicUrl, Promise, HTTP text/JSON/form/binary/multipart, cancellation,
  timers, buffer UTF-8/base64/hex, MD5, AES-128-CBC/ECB, public RSA NoPadding and
  randomBytes. Binary multipart inputs must be in memory; file/stream parts and
  zlib are unsupported. Only existing search/import metadata is passed to scripts;
  missing media IDs or quality hashes cannot be fabricated. Not every LX source
  is compatible.
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
