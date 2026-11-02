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
- Local peers/renderers stop on offscreen/navigation/background unless explicit
  PiP owns them. Failed owned deletion is retained/retryable; fresh-auth cleanup
  requires the same independently verified account and exact server address.
- Native RTCMTL inline rendering and same-track sample-buffer PiP remain;
  there is no second peer/decoder/encoder. No invisible Camera Tour warmup.
- Diagnostics use decoded-track callbacks and sanitized candidate type/protocol,
  frame counters and timings, not SDP, credential or address logging.

Normal TLS/ATS, API cookies/write CSRF, audio/mute and fold-aware layout remain.
Notification renewal preserves the installation's actual camera selection,
including `camera_ids: []`, confidence policy and private photo behavior.

## Current delivered binary: TestFlight 1036

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
