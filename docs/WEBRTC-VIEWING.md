# Native owned WebRTC viewing

## Deployment boundary

This client targets the upcoming server-owned OME/Coturn integration, not the
previously deployed HLS player. The owner's supplied contract says the LIVE
server implementation is tested in source and its image builds, but is **not
deployed or runtime-qualified**. Recorded WebRTC source/control support is not
implemented by that live API. Missing support produces upgrade/unavailable
states, never HLS or direct-original streaming.

No server deployment/settings/camera activation or notification test is part of
this client work. Original recording, storage, retention, detector and export/
download policies remain unchanged. CPU encoding is server-owned; the client
does not promise NVIDIA acceleration.

## Live implementation

- Discover authenticated `GET /api/native/features`; require version 1
  `live_webrtc`, exact `frigate-rest-offer-answer-v1` signaling and on-demand
  original-source storage semantics. Storage fidelity is not VOD capability.
- Resolve status/session resource URLs within the configured HTTPS API
  origin and reverse-proxy subpath. Encode the camera as one path component.
  Answer/candidate/heartbeat/quality/close paths must match this owned UUID.
  Signaling requests reject redirects, credentials/query fragments and
  out-of-API endpoints before forwarding auth or SDP.
- Grid requests its discovered `grid_height`, no audio, no forced relay.
  Detail Auto/pins use advertised detail heights; Data Saver requests 720p/720p,
  never a grid-only 360p rung. A force-relay switch is explicit diagnostic
  opt-in, not the normal default.
- The pinned native WebRTC SDK accepts the SERVER offer, returned ICE servers,
  policy and candidates. No client offer, WHEP, direct engine WebSocket or
  camera/go2rtc URL is used. It creates a receive-only answer with no camera,
  microphone or sender track. Audio playout uses playback-only AVAudioSession.
- Answer POST and candidate POST require 204. Local candidates are held until
  answer acceptance and sent in batches <=32 with SDK MID/index preserved.
  Null end-of-candidates is never posted.
- Heartbeat PATCH begins while negotiating, renews the short lease and applies
  temporary credential updates through the existing peer configuration.
  Unconfirmed update/expiry stops local playback and issues owned DELETE;
  credential updates do not trigger routine healthy-peer teardown.
- Exact quality/Auto PATCH uses the existing peer. Changed cap, mode, audio
  envelope or diagnostic route may create a fresh session only after old
  cleanup is accounted for. It does not silently choose another protocol.
- Creation is not canceled after dispatch: a late 201 is decoded for its UUID
  and DELETE is awaited even when its view/account generation has ended.
  Malformed returned resource URLs cannot redirect cleanup to an engine.
  Unknown creation identity is surfaced, not replayed.
- Local peers/renderers stop synchronously on navigation/offscreen/background
  unless retained by explicit PiP. Server leases are only a crash/loss safeguard;
  DELETE is attempted for each known owner. Failed deletion is retained and can
  be retried from the app-level cleanup notice before starting another pipeline.
- Camera Tour switches its single active camera without an invisible incoming
  warmup peer. This intentionally trades the old preloaded handoff for strict
  on-demand ownership. Normal camera/rate/quality changes never alter recordings.
- Native inline rendering uses RTCMTLVideoView. PiP renders the same decoded
  track through AVSampleBufferDisplayLayer, with bounded frame delivery and
  rendering-only color/crop/orientation conversion, not a second peer, decoder,
  resize/re-encode pipeline or AVPlayer WebRTC adapter.
- Diagnostics start at actual SDK decoded-frame callbacks, not offer receipt.
  Sanitized stats expose selected candidate type/protocol/relay protocol and
  frame counters, never addresses, SDP, tokens or TURN credentials.

Existing API cookies and write CSRF headers remain in use. No TLS/ATS exception,
notification camera-scope write or test push is added to video startup.
`camera_ids: []` continues to mean no camera alerts; the preceding actual-
selection/serialized-renewal fixes remain.

## Recorded playback: not implemented by the live API

Recorded/event/export/preview/camera-SD streaming now explicitly shows an
upgrade requirement. No live session is substituted and no HLS/original-file
AVURLAsset is created. Catalog navigation, thumbnails, bookmarks, protection
controls and original-file downloads/exports remain.

`RecordedViewingSession`, source selection, capabilities and authoritative
position/generation interfaces are prepared. The only implementation is a
test-only fake. Timeline unit tests reject stale generation/sequence updates
and cannot be presented as working production seeks. Existing AVPlayer-typed
UI observables are compatibility controls without a media item or network
loader; their play/seek actions never change a server source.

### Proposal for owner coordination (NOT deployed or invoked by this app)

The backend owner must define and qualify a separate recorded-viewing feature.
Suggested versioned DTOs, not claims about existing endpoint names:

```json
{
  "recorded_webrtc": {
    "version": 1,
    "enabled": true,
    "available": true,
    "discovery_url_template": "SERVER_DEFINED_CAMERA_SCOPED_PATH",
    "signaling": "frigate-rest-offer-answer-v1",
    "timeline": "authoritative-source-time-v1",
    "shared_viewer_budget": true
  }
}
```

Creation should accept only an authorized camera plus catalog identity:

```json
{
  "source": {"kind": "recording_range", "start": 1800000000, "end": 1800000060},
  "height": null,
  "max_height": 1080,
  "audio": true,
  "force_relay": false
}
```

Other source kinds need documented event/export IDs or a camera-bound SD
recording identity, never paths, source URLs, storage secrets or FFmpeg options.
The response should advertise its OWN ladder, rates, play/pause/seek capabilities,
offer/ICE and scoped answer/candidates/heartbeat/quality/close/control/position
resources with the same ownership/expiry safety as live viewing.

Control and authoritative acknowledgement need an epoch/generation fence:

```json
{
  "command": "seek",
  "source_timestamp": 1800000030,
  "generation": "CLIENT_GENERATED_UUID"
}
```

```json
{
  "generation": "CLIENT_GENERATED_UUID",
  "sequence": 21,
  "source_timestamp": 1800000030.04,
  "playing": false,
  "rate": 1,
  "media_epoch": "SERVER_DEFINED_SDK_OBSERVABLE_FRAME_FENCE",
  "gap": false
}
```

Generation-tagged position JSON alone is insufficient to identify stale
already-decoded WebRTC frames. The backend must specify a public-SDK-observable
track/frame epoch boundary or equivalent verified fence for seek transitions.
The client must not infer the recording playhead from live elapsed/wall time.
Pause must stop encoding while retaining only bounded resume/read-protection
state. Gaps, removals, archive lookup, accurate boundary seeks and supported
rates require authoritative acknowledgement. Intermediate copies must be
temporary, bounded and cleaned up under the shared live/recorded CPU budget.

Until that contract and actual source adapter are qualified, recorded viewing
remains unavailable even if live discovery says `recordings: original_source`.

## Required physical/runtime acceptance still pending

- Deploy/enable the live integration under its separate owner workflow.
- Actual grid/detail decoded frames, cold/warm first-frame timing, Data Saver,
  Auto bandwidth changes without peer recreation and pin/Auto transitions.
- Audio/mute/orientation/PiP; offscreen/background/canceled-create cleanup.
- JWT expiry, camera revocation, capacity, interrupted signaling and recovery.
- LAN, actual cellular and explicit forced relay with selected ICE stats.
- Sustained relay beyond credential lifetime; do not infer TURN/TLS from ports.
- Server evidence of final-viewer encoder/input shutdown and unchanged originals.
- A deployed recorded-session contract, real adaptive recorded frames and
  measured seek/gap/position/pause/rate accuracy, not mocked UI movement.

This Windows session has no physical iPhone or deployed OME runtime access.
Fixtures, contract tests, native device compilation and TestFlight distribution
cannot satisfy those runtime/relay/device gates.
