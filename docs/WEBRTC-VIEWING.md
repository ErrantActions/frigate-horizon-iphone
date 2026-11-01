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

The deployed backend still uses the **old recorded WebRTC path**. Recorded HTTP
schemas are draft, uncommitted and unvalidated: no HTTP manager/router/range
endpoint or discovery field is supplied. A version string or live feature does
not enable recorded HTTP. The app never calls guessed recorded endpoints.
See [RECORDED-HTTP-REVIEW.md](RECORDED-HTTP-REVIEW.md).

Client source `c6f904d` is qualified by
[unsigned run 41340057036](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41340057036):
362 Core tests, 65 committed guards and generic iOS-device Release build passed.
Native macOS authenticated MP4/AVPlayer fixtures passed; no physical-device or
deployed recorded-HTTP result is claimed. No new TestFlight build was uploaded.

No server agent contact, server deployment/settings, DNS/router changes,
camera activation, source/retention/detector/Coral changes or test push is part
of this work. The latest attachment prohibits deployment from this workstream:
this update uses tests and an unsigned generic-device build, not TestFlight.

## Live implementation retained

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

## Historical delivered binary

TestFlight **1034**, source `7bb4ab9`, remains the latest uploaded binary:
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
also requires its finalized and deployed discovery/OpenAPI/range contract.
Do not revive any retired transport to conceal these boundaries.
