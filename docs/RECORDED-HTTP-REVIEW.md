# Deployed recorded HTTPS MP4 v1: native client

## Authority and schema evidence

The latest owner handoff reports the HTTP backend/browser deployed. Initial
HTTP qualification was `0.19.0-d5af223c45bc-horizon`; Original arbitrary-offset
packet clocks are repaired in `0.19.0-7def9a838805-horizon`. A version string
does **not** authorize playback: the client requires authenticated per-camera
discovery and the supported v1 fields.

The latest handoff adds direct closed-original delivery in
**`0.19.0-7c6782c7c729-horizon`**. The client now checks the authenticated
generated OpenAPI request/response schemas before sending `delivery`,
`video_codecs` or `audio_codecs`. Discovery still reports version 1 and has
**no direct-delivery feature flag**; neither that version nor server version
strings can safely negotiate these fields. Older contracts reject them.

The published owner branch is
[webrtc-only-media-20261101](https://github.com/ErrantActions/Frigate-Horizon/tree/webrtc-only-media-20261101),
pinned for the current direct-original work to
**`7c6782c7c72990ec69adb00067dfe08e5457bfdc`**:

- [Request models](https://github.com/ErrantActions/Frigate-Horizon/blob/7c6782c7c72990ec69adb00067dfe08e5457bfdc/frigate/api/defs/request/recorded_http_body.py)
- [Response models](https://github.com/ErrantActions/Frigate-Horizon/blob/7c6782c7c72990ec69adb00067dfe08e5457bfdc/frigate/api/defs/response/recorded_http_response.py)
- [Router](https://github.com/ErrantActions/Frigate-Horizon/blob/7c6782c7c72990ec69adb00067dfe08e5457bfdc/frigate/api/recorded_http.py)

A local isolated FastAPI 0.143/Pydantic 2.14 fixture generated OpenAPI from
those published router/model definitions and validated seven operations,
202/204, HEAD, the 30-second limit, next/empty fields and resolver schema.
This is source/schema evidence, not a launched backend. Read-only normal-TLS
`GET https://dvr.errantactions.com/api/openapi.json` returned **401** without
sign-in. No credentials, server-agent contact, production sessions or backend
deployment were used for this validation.

Owner-reported browser evidence: HEAD 200; exact 16-byte Range 206; invalid
range 416; 720p decoding; repaired 11:59:58 to 12:00:42 hour continuation.
Twenty-second 720p/1080p preparation from 4K/~25 fps was about nine seconds.
None of this is an iPhone/AVPlayer or native latency qualification.

## Production client wiring

`RecordingPlayer` now constructs `RecordedHTTPAPITransport` through
`HorizonRecordedHTTPClient`, not the former unavailable/draft adapter.
The API retains its verified immutable account, HTTPS origin/proxy subpath,
supported cookie login, write CSRF and redirect rejection.

Per-camera `GET {camera}/recordings/http/status` must advertise v1, enabled/
available, `https_mp4`, `http_byte_range`, maximum 30, originals unchanged,
no HLS fallback and recognized advertised qualities. Returned `session_url`
and `resolve_url` must match that camera's published API scope. Discovery
does not create or probe a recording pipeline.

- POST the returned session URL with version/after/before/
  start_timestamp/quality/`start_policy: next`; accept **202 preparing**.
  On the OpenAPI-confirmed new contract, Auto/Original add `delivery: auto`
  and confirmed native H264/AAC/MP3 decoder lists. Explicit scaled qualities/
  Data Saver use `delivery: prepared`. HEVC is not advertised without actual
  profile evidence. Older or inaccessible metadata leaves all new fields
  omitted, with an explicit compatibility notice for inaccessible metadata.
- Poll only returned owned status URLs, bounded by time/attempts/hard expiry.
  Validate immutable after/before/requested start/next anchor and exact owned
  camera/UUID status, close and media URLs.
- Ready uses **effective_start_timestamp**, mapped through measured
  source/media spans. Original keyframe lead/nonzero media origin and unequal
  span durations are not rebased or fabricated.
- Empty has no playable asset. Its session is closed before a bounded resolver/
  replacement. No HEAD/range/native decoder is started for empty/preparing.
- `next_timestamp == before` is the continuation anchor, not a rounded last
  span endpoint. For direct originals, before/next clip to the selected file's
  playable end; only prepared windows must equal requested before. A direct
  clipped interval can be shorter than the creation request's minimum duration.
- Resolver POST contains version/after/before/start_timestamp, **no quality**,
  at most 3600 seconds and target strictly before before. Effective timestamps
  are validated against the requested bounds. Null/exhausted is missing
  footage in that search; null/unexhausted is an explicit search-limit message.
  Empty resolution gets only one bounded replacement, not an endless loop.
- DELETE uses the exact known owned UUID. Late creation remains awaited and
  deleted; malformed returned metadata with a known UUID is canonically
  deleted. Unknown creation is quarantined; failed closes retain cleanup debt.

The published HTTP contract selects **camera recording time ranges**. Event
review can use its supplied camera/catalog bounds. It does not supply arbitrary
export-file or camera-SD source binding. Those sources remain explicit
unsupported/gated viewing states; the app never plays a different recording
or an original download URL as their fallback.

## Native media, continuation and ownership

Ready media gets authenticated HEAD validation for stable length, MIME,
byte-range support and a strong ETag. Small authenticated range reads verify
`ftyp` and a valid bounded `moov` box; prepared windows require faststart,
while `original_file` can retain the original tail index after `mdat`.
Box-header offsets skip media bytes; there is no packet scan, copying,
remuxing or encoding in the native direct path. A second HEAD confirms length/ETag.
Ready atomic completion is a verified property of the pinned server contract,
not an invented `ready`/growing-file assumption.

The real AVPlayer asset uses documented AVAssetResourceLoader APIs. Every
range GET uses documented HTTPCookie request headers with private memory-only
domain/path/security/expiry matching and response cookie updates. No private
AVURLAsset headers, auth URLs, exposed proxy, TLS/hostname bypass or shared
media cache is introduced. Reads are bounded to 1 MiB, at most eight loader
requests, with exact 206 offset/end/total/body validation and correct EOF/416.
Unbounded full-200 responses are rejected before buffering.

Initial requests normally prepare **10 seconds or less**, not 30 for every
click. An upcoming continuation normally requests **20 seconds or less**.
Only one upcoming owned window may prepare while the current native viewer
is visible (including explicit visible PiP), actually playing and approaching
its boundary. Lead time scales measured preparation time to the next window
duration plus a two-second margin and native playback rate for derivatives.
Direct-original lead uses measured readiness without scaling by request duration.

No upcoming AVPlayer/asset/video output is created: only preparation/status/
small header verification occurs until handoff. Additional admission failure
is visible without terminating healthy current playback or looping per frame.
Pause, seek, quality change, hiding and stop cancel the upcoming slot, including
late creation cleanup. The old visible owner closes at handoff. There is no
HTTP heartbeat, permanent warming job or fallback transport.

In-window scrubs use the same native item and HTTP ranges. Source/media gaps
are explicit; next actual spans use native seeks and a visible notice rather
than interpolation. Outside-window seek and quality preserve latest catalog
position and play/pause intent. Auto/Data Saver are conservative advertised
window choices/replacements, not a claimed seamless ABR ladder.

AVPlayerViewController provides native play/pause/rate/PiP. Scope changes and
non-PiP background/hiding cancel loaders, clear items and close owners.
Main-actor PiP callbacks are token/API/camera fenced. Scene resume reattaches
only the same explicit PiP/catalog owner. Native fold-aware UI, audio/mute,
notification opt-outs/confidence/private photos and independent original
downloads/exports remain.

Diagnostics include window preparation, native readiness, video-output decoded
frame and seek-to-decoded-frame times, access-log drops/stalls/error codes.
Delivery mode and explicit `preparation_reason` are surfaced without resolution
badges. Live diagnostics expose confirmed create HTTP 201, answer HTTP 204 and
successful heartbeat counts; the latest live repair remains in source and
heartbeat PATCH has no invented body.
Missing values are not observed. Private URLs, original paths and credentials
are not logged; decoded output is not claimed to be first displayed video.

## Validation commands and evidence boundary

```powershell
python -m unittest discover -s tools\tests -p test_webrtc_viewing.py
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
```

Existing CI runs:

```sh
python3 -m unittest discover -s tools/tests
swift test
xcodebuild -project FrigateHorizon.xcodeproj -scheme FrigateHorizon \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Tests use isolated v1 control responses and locally generated H264 MP4 HTTPS
URLProtocol fixtures. They validate discovery, 202/poll/empty/effective/next/
resolver, scope rejection, Original lead, native cookie/range/HEAD/faststart,
same-item decoding/seeks, cancelled/late/admission/paused ownership and one
upcoming slot. They are not production-session/device evidence.

Source **`0ef3b9f`** passed
[qualification 41367976945](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41367976945),
job `125032133316`.

| Exact check | Result |
| --- | --- |
| `swift test` | **372 tests, 0 failures** |
| `python3 -m unittest discover -s tools/tests` | **67 committed guards passed** |
| `python -m unittest discover -s tools\tests -p test_webrtc_viewing.py` | **18 focused local guards passed** |
| Generic iOS-device Release command above | **BUILD SUCCEEDED** |
| Source-generated pinned OpenAPI fixture | Seven operations and deployed model constraints validated |
| Native macOS cookie/HEAD/range/faststart/AVPlayer decode/same-item seeks | Passed isolated fixtures |
| 202/poll/empty/effective/next/resolver/Original lead | Passed v1 fixtures |
| Upcoming slot, late cancellation, admission, paused ownership | Passed lifecycle fixtures/guards |
| Authenticated production/native playback; physical iPhone measurements | Not run |
| Simulator/UI tests, signing, archive/upload/TestFlight, backend deployment | Not run |

The first native run caught an exact floating-point fixture assertion
(`11.999999999999998` versus `12`); its explicit 1e-9 tolerance was corrected.
Playback timestamps were not rounded/rebased to make that assertion pass.
The owner subsequently explicitly requested TestFlight. **1035** now contains
this client: [release 41368787708](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41368787708),
source `8e4aeef`, signed app/NSE archive/export/upload passed with 372 Core/67
guards. Apple build `ee7e8ab8-e189-46be-92cd-46b78ed2a2e3` is VALID,
`usesNonExemptEncryption=false`, IN_BETA_TESTING, Owner Testing Auto. No
simulator/UI tests, backend deployment or test push was performed.
`APNS_IMAGES_BACKEND_READY=false` remains unchanged. This native release
authorization does not imply server-deployment authority or iPhone qualification.

Changed client surfaces:

- [RecordedHTTPAPITransport.swift](../Sources/HorizonCore/RecordedHTTPAPITransport.swift):
  actual discovered v1 routes, typed control client/resolve DTOs, canonical
  camera/UUID ownership and HEAD/faststart checks.
- [RecordedHTTP.swift](../Sources/HorizonCore/RecordedHTTP.swift):
  30-second cap, next/empty/effective fields, bounded planner, latency-based
  continuation policy and owned preparation.
- [HorizonRecordedHTTPClient.swift](../App/Networking/HorizonRecordedHTTPClient.swift)
  and [HorizonAPI.swift](../App/Networking/HorizonAPI.swift): verified account,
  existing authenticated API/CSRF and response metadata bridge.
- [RecordedMP4Reader.swift](../Sources/HorizonCore/RecordedMP4Reader.swift):
  bounded authenticated header-verification reads beside the native loader.
- [RecordingPlayer.swift](../App/Media/RecordingPlayer.swift) and
  [ReviewWorkspaceView.swift](../App/Views/ReviewWorkspaceView.swift):
  effective source start, one upcoming slot, canonical hour/window continuation,
  native in-window/next-span seeks, resolver/notice/intent handling and metrics.
- [Localizable.strings](../App/en.lproj/Localizable.strings), v1 API/native-media/
  ownership tests, viewing guards and directly related documentation.

Unrelated dirty xtool work was not staged. Notifications, source recordings,
downloads/exports, server settings/deployment and DNS/router/provider settings
were not changed; no test notifications were sent.

## Required remaining acceptance

The direct-original work is qualification-only until the native build/tests
complete; its final results are recorded below. Historical 0ef3b9f/1035 results
above do not qualify the new direct-original client.

On a real iPhone with the deployed server: authenticated MP4 HEAD/ranges and
206/416, cold/warm tap-to-frame and seek latency, repeated in-window seeks,
outside/empty/gap/hour continuation, paused quality changes, audio, admission,
idle/background/PiP/restoration and final cleanup. Check original download/
export behavior independently. Native live H264/audio, grid/detail transitions,
long direct/relay peers, TURN TLS and WAN/cellular remain separate unverified
acceptance. Do not claim browser fixtures certify any of these.
