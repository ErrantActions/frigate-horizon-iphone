# Recorded HTTPS MP4 review: client architecture, not deployed integration

## Gate and interfaces

The owner-approved replacement for recorded WebRTC is native AVPlayer over
completed immutable faststart MP4 windows with authenticated HTTP byte ranges.
The supplied HTTP schemas are **draft**. Discovery location, HTTP manager/router,
resource routes and OpenAPI are not finalized or deployed.

`RecordedHTTPTransport` provides typed discovery, source selection/bounds,
create/status, verified media information and owned close operations. It has
no guessed route names, heartbeat/activation endpoints or recorded WebRTC
controls. An adapter must be qualified against a finalized contract separately
from server-advertised capability version. `fixture` qualification is an
explicit test injection, not a JSON flag.

Production `RecordingPlayer` deliberately constructs
`UnavailableRecordedHTTPTransport`. Live discovery/storage metadata and
`0.19.0-d93250f20a6d-horizon` cannot bypass that gate. Its unavailable UI is not
a mock claim of HTTP integration. No production recorded media request is made.

The draft types follow version/after/before/start_timestamp/quality, ready/
preparing/failed/cleanup_pending status, opaque session identity and returned
resource URLs. Typed advertised qualities include only recognized options;
the UI exposes none until qualified discovery supplies them.

## Real client player path prepared

- `RecordedHTTPWindowManager` serializes dispatched creation, coalesces canceled
  replacements, awaits late creation and closes the known owner. Uncertain
  create outcomes block replay; known 401/403/admission failures stay distinct.
  Preparation polling is bounded. Failed close retains cleanup debt for retry
  instead of declaring server work stopped. There is no recorded heartbeat.
- A request normally prepares **30 seconds or less**, not the 120-second
  maximum. Source start lies within the exclusive end bounds. Old ownership
  is closed before new preparation; no invisible warmup/prefetch job is added.
- `RecordedHTTPMapping` maps **actual native item time** through explicit
  source/media spans, including unequal durations and nonzero media origins.
  Source/media gaps are not interpolated; forward playback ends at a
  discontinuity. An in-window scrub keeps its item/window and uses native
  seek; outside-window intent replaces a bounded window. Stale seek callbacks
  and late generations cannot resume the wrong intent.
- Quality replacement preserves catalog position and paused/playing intent.
  Auto is a bounded-window choice, not promised seamless ABR. Data Saver
  chooses only a conservative advertised derivative. Native rate controls
  check the ready item's capabilities.
- `RecordedMP4Asset` uses documented `AVAssetResourceLoaderDelegate` APIs with
  a private per-asset custom scheme. It supplies real content information and
  bounded reads; it is **not** the retired custom-scheme HLS experiment.
- Its authenticated reader performs **every** range GET using a private
  memory-only cookie store seeded with existing secure API cookies and
  `HTTPCookie.requestHeaderFields` on URLSession requests. Domain/path/security/
  expiry matching is explicit and response cookie updates stay private. Public
  AVFoundation resource requests do not rely on private header options.
  Cancellation cancels the exact URLSession read; local shutdown clears the
  native item, cancels the asset/reader and issues owned close.
- All returned resources resolve under the HTTPS API base, retaining proxy
  subpaths. Foreign origins, out-of-API URLs, traversal, credentials/query
  auth and redirects are rejected before cookies are attached. Normal TLS/
  hostname validation remains.
- Reads are capped at 1 MiB each, with at most eight loader requests, no shared
  URL/media cache. 206 offset/end/total, body length and stable total must agree.
  416 must describe a true EOF with the known length; normal EOF avoids an
  unnecessary request. A full 200 is rejected before unbounded buffering.
  The former live-HLS full-200 rule does **not** apply to VOD ranges.
- `AVPlayerViewController` supplies native rendering/playback and explicit PiP.
  Only the explicit PiP owner survives background/offscreen. Account/API/
  permission changes stop its item; live/recorded PiP ownership is exclusive.
  Navigation restoration and physical PiP behavior remain device acceptance,
  not something demonstrated by a model/fixture.
- Recorded review, exports and recording range UI now use catalog timestamps,
  typed identities and localized HTTP readiness/errors/controls. Incident/
  camera-SD viewing remains gated until finalized source-capability bindings
  exist; none substitutes live or a download URL.
- Diagnostics separate player readiness, video-output decoded frame and
  native-seek-to-decoded-frame timings. Missing values are "not observed".
  Stall/access-log dropped frames/error codes are retained without private
  paths or request/credential logging. These are not first-displayed-frame
  or real-device certification claims.

Original-quality download/export requests, storage policy, retention, source
recording quality and notification registration/selection were not changed.

## Contract blockers before enabling production

1. Finalized discovery location/schema and OpenAPI resource URLs, source
   bindings for time ranges/events/exports/previews/SD, supported qualities and
   admission/auth/error/expiry/idempotent close semantics.
2. Deployed HTTP manager/router/range endpoint and qualified capability.
   The old recorded WebRTC API is not a fallback or proof of this capability.
3. Evidence/metadata establishing completed immutable files, stable length,
   faststart, correct 206/416/Content-Range and authoritative timeline spans.
   Draft `ready` alone cannot manufacture the media-info guarantees required
   by this client abstraction.
4. On a real iPhone: authenticated repeated range reads, in/out-of-window seeks,
   quality changes while paused, audio, latency, background/PiP/restoration,
   expiry/permissions, cleanup and independent original downloads/exports.

No server agent was contacted, server configuration/deployment/DNS/router
modified or test push sent. No TestFlight/deployment is authorized by this
attachment; qualification uses the existing **unsigned** device build only.

## Validation

Local Windows command:

```powershell
python -m unittest discover -s tools\tests
```

Passed 72 local guards (includes existing untracked experimental xtool tests
that are not part of this change). The committed checkout is checked separately
in CI. Native Swift is unavailable on this Windows workstation.

Existing CI qualification command:

```powershell
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
```

It runs `python3 -m unittest discover -s tools/tests`, `swift test`, and:

```sh
xcodebuild -project FrigateHorizon.xcodeproj -scheme FrigateHorizon \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

New tests cover draft gating, API resolution/subpaths, timeline gaps, native
seek decisions, paused quality replacement, late creation, cancellation,
cleanup debt, distinct auth failures, uncertain creation, exact ranges and
bounded loading. Native macOS AVFoundation/AVPlayer tests use a locally
generated H264 MP4 and an HTTPS URLProtocol fixture with inert cookies. They
are explicitly not server integration or an iPhone/simulator test.

CI result and commit/run references will be appended after qualification.
