# Native live WebRTC and recorded HTTPS MP4 review

## Current authority and deployment boundary

The latest owner handoff supersedes recorded WebRTC: live remains receive-only
native WebRTC; recorded review will use finite authenticated HTTPS MP4 windows
and native AVPlayer byte-range seeking. HLS, DASH, plaintext HTTP and recorded
WebRTC fallback are forbidden. Original downloads/exports remain separate.

The owner reports live deployed at `https://dvr.errantactions.com/`, backend
`0.19.0-d93250f20a6d-horizon`, with browser decoded video over direct and
authenticated relay UDP. That is owner-provided browser evidence, not an iPhone
qualification. TURN TLS, WAN/cellular, long-lived native peers and iOS PiP are
not certified here.

The latest owner handoff reports recorded HTTP deployed, with Original clock
repairs in `0.19.0-7def9a838805-horizon`. The native client now wires the published
v1 per-camera discovery, 202 sessions, resolver, owned HEAD/ranges and DELETE.
A version string or live feature does not enable recorded HTTP; actual
authenticated camera discovery does. The app never calls guessed endpoints.
See [RECORDED-HTTP-REVIEW.md](RECORDED-HTTP-REVIEW.md).

Historical client source `c6f904d` was qualified by
[unsigned run 41340057036](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41340057036):
362 Core tests, 65 committed guards and generic iOS-device Release build passed.
Native macOS authenticated MP4/AVPlayer fixtures passed; that source still gated
all production HTTP integration. Current deployed-v1 client qualification is
recorded in the linked HTTP handoff. No physical-device result or new TestFlight
upload was claimed by that qualification-only handoff.

Current deployed-v1 source `0ef3b9f` passed
[unsigned qualification 41367976945](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41367976945):
372 Core tests, 67 committed guards and generic iOS-device Release build.
Native authenticated HEAD/range/faststart/AVPlayer tests are isolated macOS
fixtures, not deployed-server or iPhone qualification.

Latest source adds the published `7c6782c7c729` direct-original contract behind
authenticated OpenAPI field negotiation (discovery v1 itself is unchanged).
Auto/Original prefer a compatible original file; scaled/Data Saver remain
prepared. Tail-indexed closed originals retain their bytes/index and clipped
canonical boundary. Live five-field 422 repair is preserved; diagnostics
distinguish 201/204, heartbeat successes, schema 422 and CSRF 403. No physical
iPhone result, backend/router mutation or native deployment is claimed.

Direct-original source `d0a7561` passed
[unsigned qualification 41382828248](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41382828248):
386 Core tests, 72 guards and generic iOS-device Release build. Native macOS
fixtures authenticated, decoded a tail-indexed H264 original and performed
same-item seeks. Live 201/204 and heartbeat diagnostics are instrumented,
but physical iPhone live/recorded success and latency remain unverified.

No server agent contact, server deployment/settings, DNS/router changes,
camera activation, source/retention/detector/Coral changes or test push is part
of this work. The attachment initially prohibited deployment from this
workstream; the owner's later explicit "push to testflight" authorized only
the native 1035 release recorded below. Server deployment remains out of scope.

## Live implementation retained

### Reported Review failure code 4: bounded gap search

The owner supplied build 1038 diagnostics:
`stage: window-preparation-and-range-validation`,
`failure domain: HorizonCore.RecordedHTTPError`, `failure code: 4`,
no HTTP failure status, no native readiness/decoded-frame observation.

An actual Swift NSError bridge probe in
[42332292636](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42332292636)
confirmed **code 4 is `RecordedHTTPError.gap`**. It is not inferred from enum
declaration order: the payload-bearing empty-window case is code 0, invalid
window is 3, expired is 5, and range-unsupported is 7. The generic unavailable
title was not evidence that HTTP discovery or authentication failed.

The empty-window workflow closed its session, searched only the following
hour, then called `usableTimestamp()` once. If that hour was exhausted, it
returned gap even when later footage existed in the user's selected Review
day. An isolated fixture reproduces the same code 4 with a valid frame two
hours later.

[RecordedHTTPFrameSearch.swift](../Sources/HorizonCore/RecordedHTTPFrameSearch.swift)
now advances through **fully exhausted** search chunks within the selected
catalog range. Each POST remains at most 3600 seconds, with a target strictly
before its own end. A 26-request hard bound covers a 25-hour DST day; longer
or partially searched ranges report **search limit**, not missing footage.
Cancellation stops further metadata requests. This does not open speculative
media/transcode sessions, switch cameras, change original files or interpolate
across gaps.

Both empty-initial-window recovery and in-window gap seeks use this helper.
Only after the server's searches exhaust the remaining selected range does
Review show **No recorded footage after this position**, rather than
**Recorded HTTP review unavailable**. The notice identifies a jump to the next
actual frame. Diagnostics now include a stable semantic `failure reason`
(`gap`, `search-limit`, etc.) and a distinct `frame-search` stage, so numeric
enum layout is no longer needed for diagnosis.

This fixes a demonstrated client failure path; it does not prove that the
owner's selected range actually contains later footage. No authenticated
production range response or physical iPhone retest is available here.
New tests cover multi-hour/DST searches, exclusive boundaries, full exhaustion,
partial/server/client limits, cancellation and the measured code mapping.

Source **`b7b7a34`** passed
[unsigned qualification 42332783188](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42332783188),
job `128282855259`:

| Exact check | Result |
| --- | --- |
| `swift test` | **407 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **87 committed guards passed** |
| `python -m unittest discover -s tools\tests -p test_review_gap_search.py` | **3 focused guards passed** |
| Generic iOS-device Release `CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| Old one-hour caller code-4 reproduction / later-frame search | **Passed isolated Core fixture** |
| 25-hour day, true exhaustion, server/client limits and cancellation | **Passed regressions** |
| Owner's authenticated selected range / physical iPhone playback retest | **Not run** |

```powershell
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
```

No server configuration, camera/recording/storage/notification behavior or media
transport was changed. No simulator/UI tests or TestFlight upload were run.
This source update is **not yet included in TestFlight 1038**.

### Loaded-camera selection and Review lifecycle repair

Selecting a camera previously deactivated its grid tile and opened a new
detail view with a separate session/renderer. Grid and detail are different
server creation envelopes: grid is a low rung with audio false, while detail
offers its own ladder and audio. The live quality PATCH does not promote a
grid session into the detail/audio envelope.

The app now pins the selected running grid session **before** showing the
sheet and renders that existing decoded track as an immediate preview.
It remains visible beneath detail startup/error controls until a new detail
frame arrives; then its temporary ownership is released. Dismissal, background,
permission loss, recordings/tools navigation or a bounded 25-second timeout
also releases the pin. No extra grid connection or hidden prefetch is created,
and active Group PiP ownership is not stolen. A detail connection upgrade still
occurs; this is a no-blank-video handoff, not a claim that the backend can change
grid/detail mode in place.

The reported Review failure could not be matched to an exact phone error
(the clarification prompt was unavailable). Source inspection found that the
recorded view attached ownership callbacks to a `Group` switching between
loading, unavailable and player branches. That permits content branch lifecycle
events to release inline playback during a loading-to-ready transition.
The host is now a stable `ZStack` with a continuously mounted native player
controller and separate loading/error overlays; content transitions no longer
own teardown. Real screen departure/background/account cleanup still does.

Review also rebuilds its day/elapsed-time range on reopening, and awaits known
departing live-viewer cleanup before admitting an MP4 window. Unidentified
live creation now correctly prevents declaring cleanup drained. Intentional
PiP viewers are not silently stopped to make room.

Playback diagnostics are now available even after failure clears capability
controls. They retain the last playback stage, HTTP status, failure domain/code
and AVPlayer error-log codes, without URLs, cookies, source paths or private
session material. This makes any remaining device/backend-specific failure
actionable instead of losing diagnostics when the item stops.

Changed surfaces:
[LiveCameraHandoff.swift](../App/Media/LiveCameraHandoff.swift),
[LivePlaybackSession.swift](../App/Media/LivePlaybackSession.swift),
[LiveView.swift](../App/Views/LiveView.swift),
[RecordingPlayer.swift](../App/Media/RecordingPlayer.swift),
[ReviewWorkspaceView.swift](../App/Views/ReviewWorkspaceView.swift),
and [OwnedWebRTCViewer.swift](../App/Media/OwnedWebRTCViewer.swift), plus related
localization/tests.

Source **`cf090f5`** passed
[unsigned qualification 42307508639](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42307508639),
job `128200477618`:

| Exact check | Result |
| --- | --- |
| `swift test` | **398 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **84 committed guards passed** |
| Generic iOS-device Release `CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| Native macOS authenticated MP4/closed-tail-index decode and same-item seeks | **Passed existing fixtures** |
| Handoff ordering/bounded ownership, stable recorded host, post-failure diagnostics | **Source regression guards passed** |
| Review reopening range/date bounds | **Core regression passed** |
| Physical iPhone selection latency / reproduction of reported Review error | **Not run; exact error unavailable** |

```powershell
python -m unittest discover -s tools\tests -p test_playback_handoff_review.py
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
```

The initial source guards failed against the missing handoff/branch-owned
recorded UI before the patch; all five now pass. These are not a physical
SwiftUI lifecycle reproduction or proof that the owner's unknown backend/
device error is resolved.

The owner's subsequent explicit TestFlight request shipped the repairs in
**1038**, source `05acc72`, through
[release 42327932032](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42327932032),
job `128267491446`: **398 Core tests, 84 guards**, full app/NSE signing,
archive/export/upload passed. Apple build
`cc3d63fe-2af7-4221-b946-269b2358d5e9` is VALID,
`usesNonExemptEncryption=false`, IN_BETA_TESTING and included in Owner Testing
Auto, verified read-only. No simulator/UI tests were run.
No server settings, recordings/downloads or notification selections changed.
`APNS_IMAGES_BACKEND_READY=false` and its timestamp remain unchanged.

### Group Picture in Picture

#### Floating-window transition repair after 1038

The owner reported that Group PiP did not pop out when leaving the app.
Source inspection found automatic inline PiP disabled and a session-retention
gap before the asynchronously delivered AVKit `willStart` callback. Preview
attachment was also reported before nonzero layout, and startup had no
first-mosaic-frame gate or retry when those prerequisites arrived later.

The repaired controller exists only after the user explicitly taps Group PiP,
then enables Apple's supported
[automatic inline transition](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline).
It polls readiness within the existing ten-second bound, waits for a sized
in-window preview plus a successfully enqueued fresh mosaic frame, and records
pending ownership **before** calling `startPictureInPicture()`. An explicit
armed startup retains only its requested cameras across the app transition
until success, cancellation or timeout; an unarmed group never retains them.
Foreground navigation away still cancels an unrequested preview.

The UI distinguishes **Cancel starting Group PiP** from active PiP rather than
calling the preparation preview active. Startup diagnostics expose phase,
preview size-readiness, first mosaic frame, system possibility/active state
and AVKit/render error domain/code without private camera paths, SDP or ICE.

Group compositing is now CPU-only Core Graphics/Accelerate, including native
NV12/BGRA conversion, crop and rotation. It does not rely on a Core Image GPU
context (or a software-option assumption) while backgrounded. Ordinary inline
RTCMTL renderers detach when the scene is inactive; the explicit group owner
keeps decoded tracks and heartbeats, not offscreen Metal render views. Single
camera rendering retains its existing converter outside this group path.

New native regression tests cover readiness gates, the pre-`willStart` race,
automatic acceptance, exact timeout, cancellation/late callbacks, scene/preview
detachment, CPU colors/NV12 ranges/crop/rotation and existing mosaic placement.
The already qualified Review gap-search repair is included in the same source.
The exact phone startup phase/error was unavailable, so physical pop-out/
background/restore success is not yet asserted; qualification is recorded below.

**TestFlight 1037 is processed and available to Owner Testing Auto.** Open
Live, wait for the grid cameras to show video, then tap **Group PiP**.
The same build also contains the persistent all-camera main Live grid.

The main Live screen now offers **Group PiP** for every camera in its current
dashboard/group/favorites order. It reuses the already running low-rung muted
WebRTC sessions: no extra peer, source pull, capture track, decoder, media
server endpoint or recording derivative is started for the mosaic.

- A native CPU Core Graphics/Accelerate compositor fits decoded frames into one 960x540 sample
  buffer surface with camera labels (not resolution badges). Output is capped
  at 10 fps with one in-flight composition and one latest frame per member.
  Stale frames older than two seconds and failed/replaced tracks become black
  unavailable tiles instead of frozen video being presented as live.
- A visible native preview layer hosts the AVKit sample-buffer content source.
  PiP is armed only by explicit button, after all requested cameras have live
  frames and authorized grid sessions. Startup has a ten-second timeout and
  can transition automatically when the user then leaves the app.
- During that bounded explicit request and after native activation, the controller retains exactly those
  camera sessions across scene transitions/navigation. Other grid players
  still release normally. Closing PiP releases members without inline owners;
  cameras still on the active Live screen keep playing.
- Restoring from PiP selects Live, dismisses its camera/tools overlays and
  reattaches the same sessions rather than opening duplicate viewers. Camera
  order/filter changes stop the previous group before a new selection.
- Account/API changes or any member's permission/enable/dashboard revocation
  immediately stop/flush the group. Single-camera PiP, recorded PiP and Group
  PiP are mutually exclusive; talkback also ends Group PiP. Audio stays muted
  because members remain grid-mode audio-false sessions.
- A failed source blanks only its tile and exposes an actionable app-level
  notice. Healthy members and their heartbeats continue. No new transport or
  endless automatic connection retry is introduced.

Changed native surfaces:
[LiveGroupPictureInPictureController.swift](../App/Media/LiveGroupPictureInPictureController.swift),
[RTCGroupPiPRenderer.swift](../App/Media/RTCGroupPiPRenderer.swift),
[LiveGroupPiPPreview.swift](../App/Views/LiveGroupPiPPreview.swift),
and [LiveGroupPiPMosaic.swift](../Sources/HorizonCore/LiveGroupPiPMosaic.swift).
Single-camera and group rendering share the existing crop/rotation/I420 pixel
converter in [RTCViewerRendering.swift](../App/Media/RTCViewerRendering.swift).
Live session/attachment, root/account/PiP exclusivity, localization and tests
are wired directly. Original downloads, recordings and notifications are
unchanged. No backend/server/provider/TURN/router settings or test pushes
are part of this feature.

More cameras mean smaller tiles and greater battery/data/decoder usage. Server
admission limits are unchanged, and Group PiP does not waive existing camera
failures. Real-iPhone PiP startup, background/restore, orientation, multi-camera
power/decoder limits and prolonged playback remain device acceptance; native
compilation and compositor fixtures are not claims of phone certification.

Source **`8704097`** passed unsigned
[qualification 42302575231](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42302575231)
and signed
[TestFlight release 42303115775](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42303115775),
job `128185628289`:

| Exact check | Result |
| --- | --- |
| `swift test` | **397 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **79 committed guards passed** |
| Unsigned generic iOS-device Release build | **BUILD SUCCEEDED** |
| App/NSE profiles, Release compilation/signing, archive, export, upload | **Passed** |
| Core Image mosaic pixel placement/colors, black unavailable tiles, no retained cleared pixels | **Passed native macOS fixtures** |
| Tile completeness, order, staleness, unique authorized membership | **Passed regressions** |
| Physical iPhone multi-camera PiP/background/restore and battery limits | **Not run** |

Apple build **`9011eb69-8f8a-4d2f-a4af-d25dd99eade9`**, version **1037**, is
`VALID`, `usesNonExemptEncryption=false`, `IN_BETA_TESTING`, and belongs to
Owner Testing Auto (`2e555dfe-174b-42b5-8b03-83519d7f2fd9`), verified read-only.
The existing protected app-store workflow was approved for this owner-requested
native beta only; no external beta submission or signing/readiness-rule changes.
`APNS_IMAGES_BACKEND_READY=false` and its `2026-10-30T05:27:40Z` timestamp remain.

```powershell
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
gh workflow run testflight.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_upload=true -f allow_pending_image_backend=true
```

No simulator/UI tests, test notifications, backend/router/DNS/TURN/provider
changes or original-download mutations were performed.

### Main Live grid stays loaded while scrolling

At the owner's request, the main dashboard now owns **every camera in its
current grid**, not just tiles intersecting the scroll viewport. The former
`LazyVGrid` delayed offscreen creation and `onScrollVisibilityChange` explicitly
deactivated cameras as they scrolled away; both behaviors are removed.

[LiveCameraGridLayout.swift](../App/Views/LiveCameraGridLayout.swift) eagerly
lays out the flat camera-ID `ForEach` in
[LiveView.swift](../App/Views/LiveView.swift), so offscreen rows start on entry
and scrolling does not detach/delete their viewers. No row-index wrappers are
introduced that would replace camera/player identity when columns or order
change. Existing compact/comfortable/one-column density, accessibility sizing,
RTL, group/favorites/order filtering and disabled/revoked-camera exclusion stay.
Grid sessions still use discovered grid quality with audio false.

This increases concurrent bandwidth/decoder/server usage. Server admission
limits are unchanged; capacity denial remains actionable, not a reconnect
loop. The main Live tab/screen must still be active and foreground. Opening
detail/tools, switching tabs, backgrounding or removing camera eligibility
ends ordinary ownership; explicitly active PiP retains only its owner.
Camera Tour and recorded playback do not inherit hidden persistent players.

Source **`d3c49d1`** passed
[unsigned qualification 42299512309](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42299512309),
job `128173337428`:

| Exact check | Result |
| --- | --- |
| `swift test` | **391 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **75 committed guards passed** |
| `python -m unittest discover -s tools\tests -p 'test_live*.py'` | **7 focused guards passed** |
| `python -m unittest discover -s tools\tests -p test_webrtc_viewing.py` | **23 viewing guards passed** |
| Generic iOS-device Release `CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| Physical iPhone scroll/start-all/multi-camera capacity/battery/PiP | Not run |

[LiveCameraGridGeometryTests.swift](../Tests/HorizonCoreTests/LiveCameraGridGeometryTests.swift)
checks exact density thresholds, every row including offscreen positions,
empty/partial rows, accessibility and non-overlap across widths/camera counts.
[test_live_grid_residency.py](../tools/tests/test_live_grid_residency.py)
failed against the lazy/scroll-unload implementation before the fix and now
checks eager all-camera construction, flat identity, viewport-independent
ownership and retained tab/scene/access/PiP shutdown paths.

No server configuration, notifications, downloads or signing state changed.
This fix now ships together with Group PiP in TestFlight **1037**;
TestFlight **1036** predates both.

### Native HTTP 422 repair after build 1035

The native body already had exactly five keys, but grid creation encoded
`max_height: null`. The pinned deployed
[ViewerBody model](https://github.com/ErrantActions/Frigate-Horizon/blob/7def9a838805a38e4f48c30ad6024bc0ca2c2145/frigate/comms/live_webrtc.py)
declares nonnullable `max_height: Literal[720,1080,2160] = 1080`.
An isolated validation of the exact previous grid payload reproduced:

```text
max_height: Input should be 720, 1080 or 2160 (literal_error)
```

This is local published-model evidence, not a captured response from the
owner's phone. The response JSON/detail has not been supplied to this session.
The working backend/router were not contacted or changed.

`ViewerCreateBody.maxHeight` is now nonoptional. Grid sends the discovered grid
height, `max_height: 1080`, audio false and no extra fields; that cap does not
cause a detail rendition to be decoded by the grid. Default detail matches:

```json
{"view":"detail","height":null,"max_height":1080,"audio":true,"force_relay":false}
```

Explicit supported detail caps/pins and Data Saver remain; 4K is still an
explicit advertised choice, not the default Auto ceiling. Version/protocol/
stream/session metadata never enters the creation body.

The API now reads structured 422 `detail` arrays and preserves bounded
location/message/type information through `HorizonError.server`, the viewer UI
and copied diagnostics. `input` and `ctx` are never decoded/displayed; sensitive
locations, SDP/ICE/credentials/tokens/URLs/source paths are redacted. Text/HTML/
malformed responses have explicit safe detail or an unavailable-detail message,
not "server rejected". Auth 401/403 handling and bounded recovery are unchanged.
201 creation still follows the server-offer/client-answer flow, not WHEP.

Exact JSON, nonnull grid cap, default detail/4K intent, validation-array/
redaction/proxy regressions accompany the repair. Source **`714a9c8`** passed
[unsigned qualification 41374589104](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41374589104):

| Exact check | Result |
| --- | --- |
| `swift test` | **379 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **69 committed guards passed** |
| `python -m unittest discover -s tools\tests -p test_webrtc_viewing.py` | **20 focused guards passed** |
| Generic iOS-device Release `CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| Published-model reproduction of old null cap / valid five-field bodies | Expected rejection/acceptance |
| Real iPhone / authenticated server 201 and decoded playback after this fix | Not run |

```sh
xcodebuild -project FrigateHorizon.xcodeproj -scheme FrigateHorizon \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Changed surfaces: [WebRTCViewing.swift](../Sources/HorizonCore/WebRTCViewing.swift)
for typed payload/default ceiling and detail-preserving messages;
[ViewerValidationResponse.swift](../Sources/HorizonCore/ViewerValidationResponse.swift)
for safe response parsing; [HorizonAPI.swift](../App/Networking/HorizonAPI.swift)
for the buffered viewer-response hook; and
[OwnedWebRTCViewer.swift](../App/Media/OwnedWebRTCViewer.swift) for per-attempt
sanitized failure diagnostics. Related localization and regressions changed.
An initial compile caught the hook placed in streaming-log code; it was moved
to the correct buffered response scope and unrelated log streaming restored.
No server/router settings, notifications, accounts or original downloads changed.

The owner's later explicit TestFlight request authorized native build **1036**,
which now contains this repair and the direct-original changes. The integration
prompt still prohibits server/router deployment from this fix workstream.

- Authenticated `native/features` discovery requires live version 1,
  enabled/available and `{camera_name}/live/webrtc/status`. Optional legacy
  signaling metadata, if supplied, must agree with REST offer/answer v1;
  omitted storage metadata is not a live or recorded capability gate.
- Camera names are encoded as one component. Signaling resource URLs remain
  inside the configured HTTPS API origin/proxy subpath and exact owned UUID.
  Redirects, credentials/query fragments and direct engine URLs are rejected.
- Grid uses advertised grid height and audio false; detail uses **session**
  renditions, Auto/pins and configured caps. Data Saver caps detail at 720;
  no grid-only rung is substituted for a full-camera preference.
- The maintained pinned SDK receives the server offer/candidates, creates and
  sets a receive-only answer, then posts it. No capture tracks/client offer,
  WHEP, engine WebSocket, camera/RTSP/go2rtc API or alternate transport exists.
- Answer/candidate POST success is 204. SDK MID/index are preserved; batches
  are at most 32 and wait for answer success. Null ICE callbacks are not sent.
- Advertised heartbeat PATCH renews the lease/temporary ICE configuration;
  quality PATCH reuses the peer. Secrets/SDP/candidates stay memory-only, with
  private SDK debug logging disabled.
- Known failures use bounded recovery. Auth recovery is coordinated; 403 is
  denial, admission limits are explicit, and uncertain creation is quarantined.
  Late creation is awaited and its owned session deleted.
- The main Live dashboard eagerly loads every camera in its current authorized,
  enabled, dashboard/group/favorites selection, including tiles below the scroll
  viewport. Scrolling does not detach, pause or delete those sessions. A flat
  eager adaptive layout retains camera identity across width/density/reordering
  changes; grid quality stays the discovered low rung with audio disabled.
  All dashboard cameras consume network/decoder/server capacity while the main
  screen is active, so battery/data/CPU use can increase. Admission errors remain
  visible; the client neither changes server limits nor loops on capacity denial.
- Leaving the main dashboard (tab, camera detail or camera tools), backgrounding,
  removing a camera from the current filter, disabling it or losing access stops
  its ordinary player. Only explicitly active PiP retains its owner. Other
  viewing surfaces do not gain background or hidden warmup streams.
  Failed owned deletion is retained/retryable; fresh-auth cleanup
  requires the same independently verified account and exact server address.
- Native RTCMTL inline rendering and same-track sample-buffer PiP remain;
  there is no second peer/decoder/encoder. No invisible Camera Tour warmup.
- Diagnostics use decoded-track callbacks and sanitized candidate type/protocol,
  frame counters and timings, not SDP, credential or address logging.

Normal TLS/ATS, API cookies/write CSRF, audio/mute and fold-aware layout remain.
Notification renewal preserves the installation's actual camera selection,
including `camera_ids: []`, confidence policy and private photo behavior.

## Current delivered binary: TestFlight 1038

The owner-requested
[release 42327932032](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42327932032)
shipped source `05acc72` with 398 Core tests, 84 guards and signed app/NSE
archive/export/upload passing. Apple build
`cc3d63fe-2af7-4221-b946-269b2358d5e9` is VALID, export compliance cleared,
IN_BETA_TESTING and available to Owner Testing Auto. It adds camera-selection
handoff and stable Review host/failure diagnostics. Physical acceptance of the
reported phone symptom remains unverified.

## Previous delivered binary: TestFlight 1037

The explicit owner request shipped **8704097** in
[release 42303115775](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42303115775):
397 Core tests, 79 guards, signed app/NSE archive/export/upload passed.
Apple build `9011eb69-8f8a-4d2f-a4af-d25dd99eade9` is VALID, export compliance
cleared, IN_BETA_TESTING and included in Owner Testing Auto. This release adds
Group PiP and persistent all-camera Live grid ownership; physical playback/
background/PiP and network performance still need real-device acceptance.

## Previous delivered binary: TestFlight 1036

After the owner's explicit "push the testflight", source `c2a9e20` shipped in
[release 41391343545](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41391343545):
386 Core tests, 72 guards, full signed app/NSE archive/export/upload passed.
Apple build `bb1d1054-20b9-4def-9c9c-46297f8f5813` is VALID,
`usesNonExemptEncryption=false`, IN_BETA_TESTING and included in Owner Testing
Auto. This includes the live 422 request/detail repair and negotiated closed
direct-original playback. Server settings, notification subscriptions and
image readiness remain unchanged. No test pushes, simulator/UI tests or
external beta submission occurred. Physical-device success remains unverified.

## Previous delivered binary: TestFlight 1035

After an explicit owner request, source `8e4aeef` shipped in
[release 41368787708](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41368787708):
372 Core tests, 67 guards, signed app/NSE archive/export/upload passed.
Apple build `ee7e8ab8-e189-46be-92cd-46b78ed2a2e3` is VALID, cleared for
export compliance, IN_BETA_TESTING and included in Owner Testing Auto.
This binary contains the deployed recorded HTTP-v1 client. No server changes
or test pushes occurred; image readiness remains false and physical acceptance
is not implied by Apple processing.

## Historical delivered binary

TestFlight **1034**, source `7bb4ab9`, was the preceding WebRTC-only binary:
[release 41290042530](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41290042530).
It passed 336 Core tests, 61 CI guards, app/NSE signing, archive/export/upload.
Apple build `6c282cfd-8b0c-478a-a664-235b58b42fdc` was `VALID`,
`usesNonExemptEncryption=false`, `IN_BETA_TESTING`, Owner Testing Auto.
It does **not** contain the new recorded HTTP architecture.

`APNS_IMAGES_BACKEND_READY=false` and its existing readiness timestamp remain
unchanged. No protected release rule or NSE/signing profile was altered.

## Unverified acceptance

Real iPhone H264/audio, grid/detail transitions, pins/Auto, long-running direct/
relay sessions, TURN TLS/WAN/cellular, PiP restoration and final-viewer producer
shutdown still need authorized device/server evidence. Recorded HTTP acceptance
now targets the deployed contract, but still needs independent authorized
iPhone authentication/range/continuation/audio/PiP and latency evidence.
Do not revive any retired transport to conceal these boundaries.
