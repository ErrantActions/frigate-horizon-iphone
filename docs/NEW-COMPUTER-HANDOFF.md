# Frigate Horizon iPhone: new-computer / new-agent handoff

Updated **2026-11-09**. This document contains project state and non-secret
setup metadata only. It does not contain passwords, cookies, signing keys,
tokens or exported certificate contents.

## 1. Start here: repository and current delivery state

**Use `ErrantActions/frigate-horizon-iphone`, branch `main`.**

- Remote: <https://github.com/ErrantActions/frigate-horizon-iphone.git>
- Active old checkout: `C:\code\Frigate-Horizon-iPhone-Public`
- **Do not work in `C:\code\Frigate-Horizon-iPhone`: that is the separate
  `frigate-horizon-iphone-archive` repository.** An inherited agent working
  directory may point at that archive; explicitly select the public checkout.
- Before this documentation addition, local and remote main both pointed at
  `a7b3aacd01734032164674b003180fea7f0879f4`.
- This is a fully native SwiftUI app, not a web wrapper. Preserve iPhone /
  Duo/fold-aware layouts, accessibility and existing localization.

| State | Verified result |
| --- | --- |
| Latest delivered TestFlight | **1039**, available to **Owner Testing Auto** |
| Uploaded source | `34fd398fb8371dc35f8ba4064a4c97ae136a87a3` |
| Release | [42340612162](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42340612162), job `128307248411` |
| Release validation | **416 Core tests, 90 guards**, signed app/NSE archive/export/upload passed |
| Apple build | `84db4e76-5c44-458a-bc7c-de5e25911e99` |
| Apple verification at delivery | `VALID`, `usesNonExemptEncryption=false`, `IN_BETA_TESTING`, group membership confirmed |
| **Pushed but NOT in 1039** | **Cookie-session renewal / repeated-login repair** |
| Latest qualified implementation | `01678e85f4caf87d6746184155c75044bc3111e7` |
| Latest qualification | [42431551972](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42431551972), job `128581374888` |
| Latest validation | **425 Core tests, 95 committed guards**, unsigned generic iOS Release build passed |
| Latest pre-handoff receipt | `a7b3aac` documents that qualification; it is not another upload |

These are verified historical receipts, not proof of device behavior or a
fresh Apple/server status check on the new computer. Recheck Actions before
dispatching anything: avoid duplicate uploads. If unchanged, the next release
run would normally select **1040**, but verify the actual run/build number.

**This handoff request does not request another TestFlight upload.** Do not
silently deploy the unreleased login fix while performing workstation migration.

## 2. First actions on the new computer

Install/use trusted Git, GitHub CLI, VS Code/Copilot and Python 3 as needed.
Authenticate GitHub CLI interactively; the new workstation does not inherit
the old machine's keyring login. Never print `gh auth token`.

Example PowerShell commands; adjust the destination drive if necessary:

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status --hostname github.com
git clone https://github.com/ErrantActions/frigate-horizon-iphone.git C:\code\Frigate-Horizon-iPhone-Public
Set-Location C:\code\Frigate-Horizon-iPhone-Public
git remote -v
git status --short
git --no-pager log -5 --oneline
gh run list --repo ErrantActions/frigate-horizon-iphone --workflow testflight.yml --limit 3
```

GitHub CLI was previously outside PATH:
`C:\Users\wibeasley\AppData\Local\Programs\GitHubCLI-v2.103.3\bin\gh.exe`.
That location is machine-specific, not a new-computer requirement.

The old host was Windows without Swift/Xcode. **GitHub macOS runners performed
native tests/builds/signing. No local Mac is required to continue that flow.**
Do not install random cross-compilation tools to replace the qualified pipeline.
On a real Mac, use existing project scripts and the runbook instead.

## 3. Work that exists only on the old workstation

The following pre-existing, unrelated experimental xtool changes were left
untouched and are **NOT committed or included by a fresh clone**:

```text
 M .gitignore
 M README.md
?? docs\XTOOL-TRIAL.md
?? tools\prepare-xtool.py
?? tools\tests\test_xtool_trial.py
```

Before retiring the old computer, the owner should securely preserve those
specific modifications if wanted. Do not stage them accidentally, overwrite
them with the clone, discard them, or treat them as part of the production
build pipeline. Review their contents before transferring/committing anything.
There is no need to move build caches, virtual environments or all session logs.

The new agent should not rely on old chat attachments, session SQLite state
or absolute file paths to understand current production code. This document
and the linked committed handoffs are the portable source of context.

## 4. Most recent unreleased repair: repeated sign-in

Owner report: the app frequently requested login. Source inspection found
that native configuration refresh did not call the server's supported session
renewal endpoint. Media 401 responses also caused premature sign-in notices.

The pushed repair uses the published owner-fork contract:

- `GET /api/auth` under the configured proxy base, existing cookie auth,
  **202 / empty body**, `remote-user` / `remote-role`, optional rotated
  `Set-Cookie`. It does not invent a refresh-token endpoint.
- An actor coalesces concurrent renewal requests. Success cache is 20 seconds;
  force/failure coalescing is one second. A cancelled tile cannot cancel the
  shared check or continue its own obsolete request.
- Restore/activation and bound API requests verify the session. A 30-second
  maintenance loop runs only foreground or for explicit active PiP.
- Cookie changes persist to the current exact-address profile/device-only
  Keychain. Notifications' private image-cookie bridge refreshes without
  re-registering the device or resetting camera choices.
- MP4 ranges can obtain current cookies rather than an expired asset snapshot.
- One safe GET retry after 401; **no automatic POST/PATCH/DELETE/creation replay**.
- Media-only 401 checks the account before global sign-in. 403 remains
  access/CSRF denial, not evidence that a password is needed.
- Changed-cookie notifications are deduplicated across grid waiters.

**No password is saved.** The server cannot renew an already expired session
with this endpoint. Long idle beyond expiry, revocation/password changes or
server auth reset can still require login. Published defaults were 24-hour
sessions / 30-minute refresh window; the owner's actual values were not read
or changed. Long-running/idle-resume prompt frequency is not device-qualified.

Entry points:
[SessionRenewalCoordinator.swift](../Sources/HorizonCore/SessionRenewalCoordinator.swift),
[HorizonAPI.swift](../App/Networking/HorizonAPI.swift),
[AppModel.swift](../App/AppModel.swift),
[SavedSession.swift](../Sources/HorizonCore/SavedSession.swift),
[HorizonRecordedHTTPClient.swift](../App/Networking/HorizonRecordedHTTPClient.swift),
[RecordedMP4Reader.swift](../Sources/HorizonCore/RecordedMP4Reader.swift).
See [viewing handoff](WEBRTC-VIEWING.md) for precise tests and commands.

## 5. Current media architecture and recent behavior

Approved configured origin: **`https://dvr.errantactions.com/`**; keep HTTPS,
normal certificate/hostname validation, supported cookies and write CSRF
(`X-CSRF-TOKEN`). API base retains any proxy subpath and ends in `/api/`.

### Live

- Receive-only native WebRTC via authenticated Frigate REST signaling.
  Discover `native/features`, then camera `live/webrtc/status`.
- Creation has exactly five fields; extra fields are forbidden:

  ```json
  {"view":"detail","height":null,"max_height":1080,"audio":true,"force_relay":false}
  ```

- Grid uses advertised grid height, **nonnull `max_height: 1080`**, audio false.
  A prior `max_height: null` caused reproducible 422 validation failure.
- Creation **201**, server offer / client answer POST **204**; candidate POST
  `{"candidates":[...]}`, at most 32 per batch, preserving SDK MID/index.
  Heartbeat is **PATCH without an invented body**. Quality PATCH reuses peer.
- Actual session renditions drive detail controls; do not infer them from
  grid-only metadata. Diagnostic forced relay is explicit, never default.
- Owned late creation must be awaited/deleted. Unknown creation is quarantined,
  failed cleanup retained/retryable; scope/account/generation checks remain.
- The main Live grid eagerly loads all currently eligible filtered cameras,
  keeps them running while scrolling, and uses stable camera identity.
- Detail/audio is a different creation envelope. Selection keeps the decoded
  grid track visible during the detail upgrade via a bounded 25-second handoff;
  it does not pretend a grid session can become detail via quality PATCH alone.

### Group PiP

- User explicitly taps **Live -> Group PiP**, after all current grid feeds load.
- Reuses those peers/tracks; one native 960x540 sample-buffer mosaic at up to
  10 fps, latest frame per member, one composition in flight, labels/stale tiles.
- Explicit arming permits automatic iOS transition. Start waits for a sized
  preview, fresh mosaic and system readiness; bounded ten-second retention
  closes the pre-`willStart` race.
- CPU Core Graphics/Accelerate NV12/BGRA crop/rotation avoids group GPU drawing
  in background; inactive ordinary RTCMTL surfaces detach.
- Closing/navigation/access/account changes release non-owned sessions.
  Group/single/recorded PiP are exclusive. No extra streams or capture tracks.
- Phone pop-out/background/restore remains **unverified by the agent**, not
  established by successful Apple processing or pixel fixtures.

### Review / recordings

- Native AVPlayer, protected finite HTTPS MP4 with authenticated HEAD/ranges,
  exact 206/416 handling, stable length/ETag, bounded resource loading.
- Auto/Original prefer compatible **closed originals** when authenticated
  OpenAPI confirms `delivery`/codec fields. Older version-1 contracts reject
  those extras; discovery version or server version alone is insufficient.
- Native decoder capabilities are checked; HEVC is conservatively excluded
  without source-profile proof. Scaled qualities/Data Saver use prepared media.
- Direct originals may have tail indexes and clipped before/next file boundaries.
  Preserve server timeline/media clock mapping; never rebase or invent footage.
- Same-item in-window seeks, bounded replacements and one upcoming preparation
  only for active visible/PiP playback; cancel obsolete work and late owners.
- Stable native player host survives loading/ready transitions; failure
  diagnostics stay shareable after teardown.
- Reported `HorizonCore.RecordedHTTPError` **code 4 was measured to mean gap**.
  A premature one-empty-hour stop was fixed with bounded multi-hour searches,
  distinct search limits and a proper no-footage state. Owner then confirmed
  an actual Review problem was server-side and the app worked. Do not attribute
  that server outage to the independently found client defects.
- Export-file / camera-SD HTTP source bindings were not defined by the camera
  time-range contract. Their explicit unsupported gates are not permission to
  substitute a different recording or original download URL.

**No HLS, DASH, MSE/JSMpeg or recorded-WebRTC fallback.** Older HLS sections in
historical docs/checkpoints are superseded. No direct camera/RTSP/go2rtc/private
engine API connections. Original downloads/exports remain independent and
original-quality; do not transcode originals to fix viewing.

More detail:
[WEBRTC-VIEWING.md](WEBRTC-VIEWING.md),
[RECORDED-HTTP-REVIEW.md](RECORDED-HTTP-REVIEW.md).
Latest inspected backend owner source was `ErrantActions/Frigate-Horizon`,
branch `webrtc-only-media-20261101`, commit
`1f39f979ccc845e0bc18c05856b98a8138c6974e`. That is source evidence, not proof
that the same revision remains deployed. Backend work belongs elsewhere.

## 6. Build and release from any authenticated workstation

Project: [project.yml](../project.yml), SwiftUI app + HorizonCore Swift package,
iOS 18 minimum, maintained WebRTC SDK pinned at 156.0.0, notification extension.
XcodeGen is declared in [Brewfile](../Brewfile). The hosted `xcode-27` runner and
existing preparation scripts resolve the real SDK; a project-file version hint
is not a reason to downgrade the release toolchain.

Small local guard command:

```powershell
python -m unittest discover -s tools\tests
```

Latest clean committed CI count is **95 guards**. Old working-tree-only xtool
tests can increase local discovery counts; don't confuse them with CI coverage.

Existing unsigned native workflow:

```powershell
gh workflow run ios.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_paid_run=true -f include_compatibility=false `
  -f device_build_only=true -f upload_artifacts=false
```

It runs guards, `swift test`, project generation, then:

```sh
xcodebuild -project FrigateHorizon.xcodeproj -scheme FrigateHorizon \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

When the owner requests/authorizes the next native beta:

```powershell
gh workflow run testflight.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_upload=true -f allow_pending_image_backend=true
```

Preserve the existing protected **app-store** environment, ID `25618848295`.
Approve only the actual requested run through its normal pending-deployment
gate; never remove reviewers/protections. Run number + offset 1000 selects the
build number. Do not redispatch on a transient GitHub error before checking
whether a run was already created.

Verify separate outcomes: guards/Core tests, app/NSE device compile/sign,
archive, export, upload, Apple processing and automatic internal-group membership.
Do not equate upload success with tester availability or physical acceptance.
The owner's release preference is **no simulator/UI tests/previews**.
Use bounded watches and saved logs; inspect exact failures, not entire secrets/
signing logs. Detailed setup: [TESTFLIGHT-RUNBOOK.md](TESTFLIGHT-RUNBOOK.md).

## 7. Signing migration: no secrets in Git or chat

**Existing GitHub secrets survive the computer move.** A fresh clone with
authorized workflow/environment access can build/upload without a local P12
or API key. Don't recreate certificates/profiles/keys or overwrite valid
secrets merely because the workstation changed.

The workflow uses **manual CI signing**, not fastlane match. It imports the
Apple Distribution P12 into a temporary keychain and uses separate app/NSE
App Store profiles. Project defaults may say Automatic; the release script
explicitly uses manual signing. [testflight.sh](../.github/scripts/testflight.sh)
is the authority.

Non-secret identities:

| Item | Identifier |
| --- | --- |
| Apple team | `QM3794NUZS` |
| Main bundle | `com.errantactions.frigatehorizon` |
| NSE bundle | `com.errantactions.frigatehorizon.NotificationService` |
| App Store Connect app | `6827721926` |
| Upload key ID | `L2W7YT7623` (team API key with issuer; not APNs provider key) |
| Automatic internal group | Owner Testing Auto, `2e555dfe-174b-42b5-8b03-83519d7f2fd9` |

Existing environment **secret names only**:

```text
DISTRIBUTION_CERTIFICATE_BASE64
DISTRIBUTION_CERTIFICATE_PASSWORD
PROVISIONING_PROFILE_BASE64
NOTIFICATION_SERVICE_PROFILE_BASE64
APP_STORE_CONNECT_KEY_ID
APP_STORE_CONNECT_ISSUER_ID
APP_STORE_CONNECT_PRIVATE_KEY
```

Repository-level secrets were empty at the earlier check; signing secrets
reside in `app-store`. `ErrantActions` is a user account, not an organization;
there is no assumed organization-secret inheritance.

Verified non-secret environment variables:
`APP_BUNDLE_ID=com.errantactions.frigatehorizon`,
`APPLE_TEAM_ID=QM3794NUZS`, `ENABLE_NATIVE_PUSH=true`,
`BUILD_NUMBER_OFFSET=1000`, **`APNS_IMAGES_BACKEND_READY=false`**.
The latter's timestamp is **2026-10-30T05:27:40Z**; do not turn it true without
separate approved backend evidence. The pending-image release input is an
explicit allowance, not a readiness attestation.

If the owner wants local backup/read-only Apple status access on the new PC,
securely transfer only the relevant owner-controlled files from the old
directory **outside this repository**:

```text
C:\Users\wibeasley\AppData\Local\FrigateHorizon\Signing\
  distribution.p12
  distribution-private.pem
  apple-distribution.cer
  AuthKey_L2W7YT7623.p8
  Frigate_Horizon_App_Store.mobileprovision
  Frigate_Horizon_Notification_Service_App_Store.mobileprovision
```

Filename existence was checked for this handoff; private contents/passwords
were not read. Use encrypted owner-controlled transfer and restricted file
permissions; no chat attachments, Git commits, clipboard dumps or plaintext
password files. Keep the P12 export password separately in the owner's password
manager. GitHub secrets cannot be downloaded as a migration method. Apple
normally allows the original API-key private download only once: preserve it.

Local provisioning profile copies may be older than working CI secrets.
Do not upload them blindly or assume they are authoritative backups of CI.
If the P12 password is lost, locate it or export the same identity from an
owner-controlled keychain holding its matching private key; a `.cer` alone is
insufficient. Do not issue/revoke certificates to solve that without approval.

[tools/apple-signing.ps1](../tools/apple-signing.ps1) already supports local
secure prompts, P12 validation and approved secret upload over stdin.
Its `UploadSecrets` action **changes variables/secrets and can create an
environment**: do not run it just to inspect/migrate existing working CI.
Never reuse Frigate's app-specific profiles for another app.

An optional read-only Apple verifier was session-local on the old PC:
`C:\Users\wibeasley\.copilot\session-state\2025762f-e15f-433b-aed3-56e98741f11f\files\verify_http_testflight.py`.
It creates an in-memory short-lived ES256 token and uses App Store Connect GETs.
It is **not committed**, and its old Python virtualenv/path is not portable.
The owner may preserve that script separately or use App Store Connect UI.
Do not copy the whole old virtualenv or print API tokens/private key contents.

## 8. Operational boundaries and next agent priorities

- Owner prefers complete, precise native fixes, tests and relevant pushes.
  Keep the manual release gate; don't treat this migration as upload authority.
- Do not contact another server agent, mutate/deploy/restart the NVR, alter
  DNS/router/TURN/camera enablement, retention/storage, detectors/Corals,
  provider readiness or credentials as part of native app work.
- **Do not send test pushes without fresh authorization.** Preserve native
  registrations, confidence/photo policy and actual notification camera scope.
  `camera_ids: []` is an explicit opt-out, not all cameras.
- Preserve profile-specific exact-origin/base-path sessions and account-bound
  cleanup. No TLS exceptions, cross-origin cookie forwarding or password storage.
- Preserve unrelated dirty work; stage exact intended files. Existing commits
  include `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.
- A real device is required for live 201/answer204/decoded video, Group PiP
  background/restore, battery/concurrency, Review audio/seeks/latency and
  WAN/cellular/TURN-TLS acceptance. Windows/native macOS fixtures and builds
  do not certify these. No agent-controlled physical iPhone has been available.
- Next actionable implementation is **already complete and qualified in
  source**: the login-renewal repair. If asked to ship, use the existing release
  flow, verify processing/group membership and append the receipt. Don't redo
  completed work or claim it is already in 1039.
- After delivery, ask for actual long-use / idle-resume results and shareable
  diagnostics before making another speculative auth or server change.

## 9. Paste into the new agent

> Open the public ErrantActions/frigate-horizon-iphone checkout on main, not
> frigate-horizon-iphone-archive. Read docs/NEW-COMPUTER-HANDOFF.md, then the
> relevant viewing/release handoffs. Latest delivered TestFlight is 1039;
> source main additionally contains qualified but unreleased cookie renewal
> (01678e8, 425 Core tests/95 guards/native Release passed). Verify current
> HEAD, dirty files and Actions before acting. Existing signing secrets are
> in the protected app-store environment and survive the workstation move.
> Never print/copy secrets into chat or Git, overwrite working CI profiles,
> change the backend or send test pushes. Preserve notification opt-outs,
> original media and account scope. Do not upload a new beta just because
> this handoff was opened; follow my next request.
