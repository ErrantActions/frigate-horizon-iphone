# TestFlight publishing runbook for agents

**Current source: live WebRTC plus capability-gated recorded HTTPS MP4
architecture.** The owner subsequently explicitly requested TestFlight;
**1037** is now uploaded, processed and available to Owner Testing Auto, with
Group PiP, persistent Live grid, live 422 repair and direct-original HTTP client.
That authorization is for the native release,
not server deployment or test pushes. The earlier HLS sections are historical.
Live and recorded HTTP are
owner-reported deployed; the current source wires authenticated recorded-v1
discovery/ranges, while physical iPhone qualification remains unverified. Do not
revive HLS, recorded WebRTC or download-URL streaming as a fallback. See
[WEBRTC-VIEWING.md](WEBRTC-VIEWING.md) for implementation, exact checks and blockers.

## Latest verified release: 1037

[Run 42303115775](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/42303115775),
job `128185628289`, source `87040970b27b93492d288e6659755c9a526d70ad`,
selected build **1037**. It passed **397 Core tests**, **79 guards**,
both app/NSE Release compilation and distribution signing, archive, export
and upload. No simulator/UI tests/previews were run.

Apple build `9011eb69-8f8a-4d2f-a4af-d25dd99eade9` is **VALID**,
`usesNonExemptEncryption=false`, **IN_BETA_TESTING**, and included in
**Owner Testing Auto** (`2e555dfe-174b-42b5-8b03-83519d7f2fd9`). External
tester groups/submission were not changed. Processing and group membership
were verified read-only through App Store Connect.

Use **Live -> Group PiP** after all selected grid cameras show live video.
The mosaic reuses those native sessions without duplicate streams; the eager
Live grid also keeps all its cameras loaded when scrolling. This includes
the earlier nonnull grid `max_height`/exact five-field creation fix,
sanitized validation details, observed live HTTP/heartbeat diagnostics and
OpenAPI-negotiated direct-original MP4 delivery with tail-index support.
TestFlight availability does not certify physical live 201/answer 204/decoded
frames, recorded latency/audio/PiP, or WAN/TURN-TLS.

```powershell
gh workflow run testflight.yml --repo ErrantActions/frigate-horizon-iphone --ref main `
  -f confirm_upload=true -f allow_pending_image_backend=true
```

The existing `app-store` environment approval was applied only to this run;
protection rules were not changed. `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp remain unchanged. No backend/provider/DNS/
router changes or test pushes occurred. Real iPhone playback, latency/audio,
PiP, WAN/cellular/TURN-TLS and independent download acceptance remain unverified.

Reusable workflow: Windows workstation, native iOS project, GitHub-hosted macOS
builds, and manual distribution signing. No local Mac is required for this path.

**TestFlight is not a public App Store release.** TestFlight uses Apple
Distribution certificates and App Store Connect distribution provisioning
profiles. Those names do not mean the agent should submit or publish the app
publicly.

## Agent handoff prompt

Copy this prompt and provide this document to the next agent:

> Help me publish this native iOS app to TestFlight using GitHub Actions.
> Follow the attached runbook, inspect the repository's actual workflows and
> signing helper, and resume from the last verified checkpoint. Confirm the
> repository, app name, bundle ID, Apple team, and intended testers. Do not
> recreate existing app records, keys, certificates, or profiles without checking
> whether they can be reused. Keep passwords and private keys out of chat,
> source control, tool output, and artifacts. Let me handle sign-in, MFA, legal
> agreements, and local password prompts. Verify the signed upload, Apple
> processing, and tester installation separately. Do not submit a public App
> Store release. Ask me before each paid macOS workflow run or rerun; an earlier
> approval does not authorize another attempt.

## 1. Confirm prerequisites and authorization

Collect only nonsecret configuration:

| Item | Confirm |
| --- | --- |
| Apple membership | Active paid Apple Developer Program membership |
| App identity | Display name, explicit bundle ID, primary language, internal SKU |
| Apple team | Correct team selected in both Apple portals; record its team ID |
| GitHub destination | Repository the owner is authorized to use |
| Build access | Hosted macOS runners enabled, or an approved self-hosted Mac |
| Testers | Owner/internal testers first, or external beta testers |
| Approval | Permission to create signing resources and upload a beta |

Use the browser for Apple sign-in. The owner enters credentials and MFA directly.
The owner reviews and accepts Apple agreements or API-access terms personally.

If enterprise policy disables hosted runners, stop and request an approved build
route. Apple authentication does not fix a GitHub runner restriction. Do not
move code to another account or organization without explicit owner approval.

Before creating resources, inspect existing app records and signing metadata.
Never revoke unrelated certificates or keys to free capacity.

### Public-repository compute, approval, and metering

This fresh public repository was created on **October 28, 2026**, without
previous Git history, Actions logs or signing material.
[Standard GitHub-hosted runner compute is free for public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
GitHub lists both current labels, `xcode-27` and `macos-26`, as
[standard public runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories).
Larger runners remain billable even for public repositories. Storage and
Apple Developer fees are separate; historical private-run charges remain.
Recheck visibility and runner classification before relying on free compute.

Workflows remain manual with confirmation required. The iOS API input retains
its historical name `confirm_paid_run`, but its UI now says manual validation.
Do not treat public visibility as permission to start a build or upload.

On October 29, 2026, the owner requested **always push**: relevant app fixes
and TestFlight retries on standard public runners have standing approval.
Do not repeatedly ask for each such attempt. Keep the workflow manual and
its protected environment intact, verify each result, and avoid redundant runs.
Paid/private/larger-runner jobs and billing changes still require explicit
approval. No monthly dollar budget is configured here; do not dispatch a paid
workflow just to verify spending controls.

The owner also authorizes ongoing feature development and pushes for the native
app and main Frigate Horizon app. Coordinate server work with the active backend
task and its approved deployment/rollback procedure; verify the authorized fork
before pushing and preserve unrelated work. This is not permission to silently
enable camera alerts, discard recordings, broaden credentials, or publish a
public App Store release.

Horizon no longer runs macOS builds on push or pull request. The manual iOS
workflow requires `confirm_paid_run=true`, defaults to one Duo job, and adds
compatibility validation only with `include_compatibility=true`. Artifacts are
opt-in and retained for one day.

For a release candidate, use the TestFlight workflow. At the owner's request,
deployment does not run simulator/UI tests or capture previews. It retains core
contract tests, signing/build guards, and real Release device compilation before
export/upload. UI acceptance happens on the owner's phone.
The separate manual iOS workflow retains simulator/native UI tests and optional
synthetic previews; run it only when requested, not automatically before a deploy.

Validation jobs have 15-minute timeouts and TestFlight has a 20-minute timeout.
Each completed reporting step adds elapsed/rounded runtime to the GitHub job
summary; these figures are **not** authoritative billed minutes or dollar spend.
Checkout failure, forced cancellation, or timeout may prevent reporting.

The owner controls account billing and spending limits in
[GitHub Billing](https://github.com/settings/billing). Never change payment
settings or increase spending limits to unblock a build without explicit approval.

Before requesting a paid run, use `bash tools/check-ios.sh` on a suitable local
macOS/Xcode host. This reuses CI setup/tests and also compiles an unsigned Release
device archive. Verify its saved Xcode/SDK, commit/worktree, and purpose-string
checks. A compatibility-only run is not proof that Duo-specific code compiles.
No local Mac is configured merely by adding this command; Windows cannot perform
the full iOS check, and signing/Apple processing still need separate verification.

## 2. Verify the project and unsigned CI

Inspect the app's actual project definition, build scripts, and workflows.
For this repository:

- [Project definition](../project.yml)
- [Unsigned iOS workflow](../.github/workflows/ios.yml)
- [TestFlight workflow](../.github/workflows/testflight.yml)
- [SDK/project preparation](../.github/scripts/prepare-ios.sh)
- [Simulator tests](../.github/scripts/test-ios.sh)
- [Archive, export, and upload](../.github/scripts/testflight.sh)
- [Early profile guard](../.github/scripts/check-profile.sh)
- [Shared profile validation](../.github/scripts/validate-profile.py)

Verify:

1. The native app compiles and its relevant tests pass.
2. The runner has the required Xcode, SDK, and simulator. Device-specific
   features must not silently compile out in the claimed device build.
3. The app has an owner-approved icon. For the conventional asset catalog used
   here, use an opaque 1024x1024 PNG, without pre-rounded corners. Preserve
   existing branding rather than inventing a replacement.
4. The bundle ID, marketing version, and build number are wired into the
   generated project and signed archive. Later uploads need an accepted,
   increasing build number for the relevant version.
5. Distribution is manual; a normal push must not upload to Apple. Review
   environment protections separately rather than assuming they are enabled.

An unsigned simulator `.app` is not an installable iPhone IPA and does not prove
that distribution signing works.

### Native push and required opt-in images

Push is disabled by default. The owner requires opt-in images before the next
TestFlight build. See [Native Apple push setup](NATIVE-PUSH.md); do not dispatch
the old text-only configuration or equate source changes with backend readiness.

The main App ID already has Push Notifications and a refreshed production APS
profile. Preserve its existing `PROVISIONING_PROFILE_BASE64` secret. The existing
production-only server APNs provider key is not the upload key and must stay on
the server.

Obtain approval for the new
`com.errantactions.frigatehorizon.NotificationService` App ID/profile, reusing
the existing distribution certificate. The extension requires its own
`NOTIFICATION_SERVICE_PROFILE_BASE64` secret and the dedicated shared Keychain
group, not the main session group. Both targets must be signed and exported with
their own profiles. The NSE does not need APS or a separate APNs provider key.

Only after explicit approval and verified deployed image support, set
`ENABLE_NATIVE_PUSH=true` and `APNS_IMAGES_BACKEND_READY=true`. Backend support
requires the advertised image capability, mutable-content alerts, and the
protected installation-scoped image endpoint with fresh account/camera checks.
Alternatively, explicit owner approval for shipping the image-capable app ahead
of the backend permits the per-run input `allow_pending_image_backend=true`.
Keep backend readiness false/unset; this does not waive NSE/profile signing,
runtime capability checks, or explicit Lock Screen image opt-in. Reopen the app
after backend deployment to refresh its capabilities.

The early guard rejects wrong team/app, expired, development/ad hoc/enterprise,
and push/Keychain-incompatible profiles before compilation, including mismatched
app/extension certificate or prefix. Final signing reuses that
validator. These checks reduce wasted runner time. Standard public-runner
compute is free; any billable runner still requires fresh approval even if
preflight fails.

No new Apple resources, variables, backend deployment, or real Apple push is
authorized by source changes alone. The standing app-build approval above does
not cover backend deployment, real pushes, public/external releases, new Apple
resources, credential permissions, or legal declarations. Validate Xcode/device
behavior before calling the feature usable.

For a different app, replace repository-specific scheme, project, bundle ID,
team, SDK, signing-directory, and workflow values before reusing these commands.
The links below point to Horizon's implementation, not a universal template.

### Node.js warnings in Actions

Inspect the warning and the referenced action's `action.yml`, especially
`runs.using`. Updating the runner's installed Node.js or adding `setup-node`
does not change another action's embedded runtime.

In this setup, `actions/upload-artifact@v5` still targeted Node.js 20. Updating
to verified Node.js 24 releases, `checkout@v7.0.1` and
`upload-artifact@v7.0.2`, removed the Node.js 20 and `punycode` warnings.
For future apps, verify current supported releases and migration requirements;
do not assume every `@v5` action uses the same Node.js runtime.

Keep GitHub Actions dependency updates enabled, with review rather than blind
auto-merging. This repository uses [Dependabot](../.github/dependabot.yml).

## 3. Register the App ID and App Store Connect record

In [Apple Developer](https://developer.apple.com/account/resources/identifiers/list):

1. Add an identifier of type **App IDs**, then **App**.
2. Enter the approved description and **Explicit** bundle ID.
3. Enable only capabilities the app actually needs.
4. Review, register, and verify that the identifier appears in the list.

In [App Store Connect](https://appstoreconnect.apple.com/apps):

1. Choose **New App** and the **iOS** platform.
2. Enter the approved name and primary language.
3. Select the matching registered bundle ID.
4. Enter a unique internal SKU and the intended user-access setting.
5. Create the record and verify its name, bundle ID, and Apple app ID.

The icon placeholder can remain until Apple processes the first build.
Do not upload an unrelated image merely to replace that placeholder.

## 4. Generate the private key and CSR locally on Windows

Use a trusted OpenSSL installation, such as Git for Windows, and an interactive
terminal visible to the owner. This repository provides
[apple-signing.ps1](../tools/apple-signing.ps1).

For another app, review and reuse/adapt the helper explicitly. Supply a separate
signing directory and the correct repository/bundle ID rather than accepting
Horizon-specific defaults.

```powershell
$SigningDirectory = Join-Path $env:LOCALAPPDATA 'YourApp\Signing'

powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action CreateCSR -SigningDirectory $SigningDirectory
```

If Windows blocks local scripts, inspect `Get-ExecutionPolicy -List`. Ask the
owner before changing policy. Where permitted, run the reviewed helper with
`-ExecutionPolicy RemoteSigned` for that PowerShell process only. Do not change
machine/user-wide policy or override organization-enforced restrictions.

The owner enters the contact email and signing password locally, not in chat.
Store the password securely; the helper needs it again for certificate export.

The helper:

- Restricts the signing directory to the current Windows user and SYSTEM.
- Generates an encrypted RSA private key and public CSR.
- Refuses to overwrite existing keys.
- Keeps the files outside the repository.

Upload **only the public CSR** to Apple. The private key never goes to the Apple
certificate-request form. Base64 is encoding, not encryption.

## 5. Issue the Apple Distribution certificate

In [Certificates](https://developer.apple.com/account/resources/certificates/list):

1. Add a certificate and choose **Apple Distribution**.
2. Upload the generated `distribution.csr`.
3. Continue to issue the certificate.
4. Download the public `.cer` into the local signing directory.
5. Export the certificate with its matching private key into an encrypted P12:

```powershell
powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action ExportCertificate -SigningDirectory $SigningDirectory `
  -CertificatePath (Join-Path $SigningDirectory 'apple-distribution.cer')
```

The owner enters the original signing password in the terminal. The helper
checks that the certificate's public key matches the private key before export.

A `.cer` alone is not enough for CI signing: the P12 must include the matching
private key. Do not use a cloud-managed certificate for this manual-export path
unless its private key is actually available through a supported method.

Keep an owner-controlled encrypted backup. Do not print or open private-key,
P12, or password contents using agent tools.

## 6. Generate the App Store Connect provisioning profile

In [Profiles](https://developer.apple.com/account/resources/profiles/list):

1. Add a distribution profile of type **App Store Connect**, not Development or
   Ad Hoc.
2. Select the exact App ID registered in step 3.
3. Select the distribution certificate from step 5.
4. Give it a descriptive name, generate it, and verify app/team/expiration.
5. Download the `.mobileprovision` into the local signing directory.

No tester device UDIDs are required for TestFlight. Do not register devices as
an unnecessary workaround.

If browser automation cannot save a download, ask the owner to download it and
provide its local path. Do not replace missing files with guessed contents or
claim a download succeeded without checking.

## 7. Create the App Store Connect API key

In **App Store Connect > Users and Access > Integrations > App Store Connect API**:

1. If API access is not enabled, the Account Holder must request it and review
   the applicable terms.
2. For this workflow, choose **Team Keys** and generate a named CI key.
3. Select the least-privileged role that permits build uploads for the intended
   workflow. Consult Apple's current role permissions; do not default to Admin.
4. The owner downloads the `.p8` once, directly into secure local storage.
5. Record the **Key ID** and **Issuer ID** for configuration.

This uploader expects a **team API key with issuer ID**. An individual key is
not interchangeable with that configuration without changing the uploader.
Apple documents that team keys can apply across apps; explain that scope to the
owner before creating one.

Do not ask the owner to paste `.p8` contents into chat or inspect them with
browser/tool output. The local helper reads the file and uploads it directly.
Never revoke an existing key without owner approval and impact assessment.

## 8. Configure protected GitHub signing secrets

Install the official GitHub CLI from a trusted source. If installing a release
archive, verify its published checksum before executing it.
If the executable is not on `PATH`, use its full installed path in commands
instead of reinstalling or exposing authentication tokens.

Authorize the correct GitHub account in an interactive terminal:

```powershell
gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow
gh auth status --hostname github.com
```

Never run `gh auth token` into agent logs. Authentication does not imply the
account has permission to administer the target repository's environments.

Create/use an **app-store** GitHub environment. Review its branch restrictions,
reviewers, and existing protections; never remove protections to make a run pass.
Use approved repository/environment settings if a plan does not support a
particular protection.

| Environment variable | Purpose |
| --- | --- |
| `APP_BUNDLE_ID` | Registered explicit bundle identifier |
| `APPLE_TEAM_ID` | Matching Apple Developer team ID |
| `ENABLE_NATIVE_PUSH` | Must be `true` for the next image-enabled release, after approval |
| `APNS_IMAGES_BACKEND_READY` | Must be `true` only after approved, verified image-backend deployment |

| Environment secret | Purpose |
| --- | --- |
| `DISTRIBUTION_CERTIFICATE_BASE64` | Base64-encoded P12 with private key |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | P12 password |
| `PROVISIONING_PROFILE_BASE64` | Base64-encoded distribution profile |
| `NOTIFICATION_SERVICE_PROFILE_BASE64` | Separate NSE App Store profile, using the same distribution certificate |
| `APP_STORE_CONNECT_KEY_ID` | Team API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Original `.p8` text, including line breaks |

Use the helper to read secrets locally and send them over stdin, not command-line
arguments, clipboard output, plaintext password files, or chat:

```powershell
powershell.exe -NoProfile -File .\tools\apple-signing.ps1 `
  -Action UploadSecrets -SigningDirectory $SigningDirectory `
  -Repository 'OWNER/REPOSITORY' -BundleId 'com.example.yourapp' `
  -TeamId 'YOURTEAMID' `
  -ProfilePath (Join-Path $SigningDirectory 'YourApp.mobileprovision') `
  -ApiKeyPath (Join-Path $SigningDirectory 'AuthKey_KEYID.p8')
```

Enter passwords and identifiers only in the local prompts. Verify secret
**names**, not values:

```powershell
gh secret list --repo OWNER/REPOSITORY --env app-store
gh variable list --repo OWNER/REPOSITORY --env app-store
```

For the existing configured repository, add only the approved extension profile
secret. Do not run a full secret replacement with the stale local main profile:

```powershell
$profile = Get-Item -LiteralPath 'C:\secure\HorizonNotificationService.mobileprovision'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($profile.FullName)) |
  gh secret set NOTIFICATION_SERVICE_PROFILE_BASE64 `
    --repo ErrantActions/frigate-horizon-iphone --env app-store
```

## 9. Run and verify the signed upload

Under the standing public-runner app-build approval, open **Actions > TestFlight >
Run workflow** on the approved
branch with the upload checkbox checked. Equivalent CLI for this repository's
workflow interface:

```powershell
gh workflow run testflight.yml --repo OWNER/REPOSITORY --ref main -f confirm_upload=true
gh run list --repo OWNER/REPOSITORY --workflow testflight.yml --limit 5
gh run watch RUN_ID --repo OWNER/REPOSITORY --exit-status
```

Confirm the workflow actually:

1. Ran core/build/signing checks and compiled the Release app on the intended SDK.
2. Validated both profiles, expiry, IDs, team, production app APS, shared group,
   and common certificate; embedded and signed the NSE with its own profile.
3. Imported the certificate/private key into a temporary keychain.
4. Archived for a **physical iOS device** destination, not Simulator.
5. Exported an App Store Connect IPA and successfully uploaded it.
6. Cleaned up its temporary keychain, profile copy, certificate files, and API
   key file, including on failure.

Keep signing secrets scoped to the signing/upload step. Do not expose them to
pull-request jobs, package-install steps, or build artifacts.

A green simulator build is not a signed upload. A successful upload is not yet a
processed, installable TestFlight build. Report each milestone accurately.

### Missing privacy purpose strings after a successful upload

Apple can accept the binary transfer and then reject the build during processing.
Check the owner's processing/rejection email if the portal still shows
**No Builds**; do not assume it is simply a queue delay.

Horizon received **ITMS-90683** for missing `NSCameraUsageDescription`. Its
bundled WebRTC binary includes capture APIs even though the app only receives
remote camera video/audio. We added camera and microphone purpose strings to
the app's actual Info.plist and a native regression test that reads the built
application bundle, not just the source XML.

Purpose strings must accurately describe the app. Do not invent capture or
talkback features to satisfy validation. Declaring a purpose string does not
grant permission or start capture. For another app, assess the linked SDKs and
real behavior, provide appropriate user-facing explanations, then upload a new
build with an increased build number and verify processing again.

### Verified uploader and the Transporter failure

The initial signed run successfully archived and exported the IPA, then failed:

```text
iTMSTransporter is now part of Transporter.
Please install Transporter from the Mac App Store.
```

The hosted Xcode runner did not include that separate app. Installing Transporter
from an interactive Mac App Store session is not required for this workflow.
We switched to Apple's supported Xcode-provided uploader:

```sh
xcrun --find altool
xcrun altool --upload-app -f "$ipa" -t ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
```

The script makes the private `.p8` available as
`$HOME/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` during upload, restricts
its file permissions, and deletes that temporary copy on exit. Check uploader
availability before the expensive signing/archive work.

After this fix, the signed workflow reported:

```text
** ARCHIVE SUCCEEDED **
** EXPORT SUCCEEDED **
UPLOAD SUCCEEDED with no errors
```

Do not regenerate certificates or rotate API keys for a missing-uploader error.
Keep the failing and successful run links so the next agent can distinguish
signing success, delivery failure, and subsequent successful delivery.

## 10. Process the build and install through TestFlight

1. Open the app's **TestFlight** tab in App Store Connect.
2. Confirm the uploaded version/build appears, then wait for processing.
3. Resolve processing errors or missing compliance information. The owner must
   confirm export-compliance answers based on the app's actual encryption; do
   not blindly set an exemption flag to suppress questions.
4. Provide beta information and create an internal testing group.
5. Add the build and eligible App Store Connect users, including the owner.
6. Install Apple's TestFlight app on the iPhone, accept the invitation, and
   install the beta.
7. Verify launch, icon, login, core features, permissions, and device-specific
   behavior on the physical phone.

Apple processing is asynchronous. A successful delivery can precede the build
appearing in TestFlight by several minutes or longer. Record the upload time,
check the processing notification/status, and investigate reported errors. Do
not repeatedly upload the same build just because the portal still says
**No Builds**. There is no guaranteed processing deadline in this runbook.

For owner-only testing, create an internal group with manual build distribution,
add only the owner, and assign the processed build. The owner needs the
TestFlight app on their phone and must accept the invitation. Do not mark the
phone test complete until the owner confirms the app actually launches.

For external testers, complete the beta-review information and any required
TestFlight App Review. Do not invite outside testers or enable a public link
without approval. Do not grant App Store Connect access merely to avoid review.

TestFlight builds expire after 90 days. Later betas normally reuse the app record
and valid signing resources, increase the build number, and repeat steps 9-10.
Obtain a fresh paid-run approval for each attempt. Do not submit a public App
Store release unless separately requested.

## Troubleshooting and handoff rules

| Symptom | Correct next step |
| --- | --- |
| Hosted runners disabled | Request enterprise approval or an approved runner |
| GitHub API/browser shows 404 | Verify private-repository access and active account |
| GitHub MCP reports header mismatch | Use authenticated official CLI or browser; do not expose credentials |
| Apple login or agreements block progress | Ask the owner to complete them directly |
| Private-key mismatch | Use the certificate issued for the original CSR; do not regenerate keys blindly |
| Existing signing files | Reuse after verification or choose a separate directory; do not overwrite |
| Signing identity/profile missing | Check certificate private key, profile selection, team, expiry, and keychain |
| Archive/export succeeded, Transporter missing | Use the verified Xcode `altool` uploader; do not recreate signing resources |
| API upload rejected | Verify team-key type, issuer/key IDs, permissions, and active app record |
| Duplicate build number | Increment the configured build number before uploading |
| Node.js deprecation warning | Update the action's runtime-compatible release, not just runner Node.js |
| App Store Connect icon placeholder | Verify the bundled icon and processed build first |
| Green workflow, no installable beta | Check actual upload, processing, compliance, and group assignment |
| ITMS-90683 / missing purpose string | Inspect the rejection email and linked SDKs; add truthful camera/microphone usage strings to the built app, test, and upload a new build |

At every handoff, record verified results, outstanding owner actions, workflow
run links, and nonsecret resource IDs. Never include secret contents or claim
that unverified steps are complete.

## Fresh public repository checkpoint

Repository: `ErrantActions/frigate-horizon-iphone`.
The app's existing bundle ID remains `com.errantactions.frigatehorizon`.
Previous private run links, account-specific publishing records and billing
details are intentionally not imported into these public instructions.

- Fresh source-only history uses the public GitHub noreply identity.
- The previous repository remains private and is not a parent or fork.
- Actions stay manual, pinned, read-only and free of persisted checkout credentials.
- The protected signing environment requires owner approval and permits only `main`.
- Signing secret values are not migrated. Re-upload them securely from existing
  local signing material before requesting TestFlight; unsigned tests need none.
- GitHub workflow run numbers restart. TestFlight uses an offset of 1000 by
  default; verify the next number exceeds existing Apple uploads before approval.
- Push remains disabled until its separate backend and signing setup are ready.
- No new Apple app registration or credential rotation is required merely
  because the GitHub repository changed.
- Latest verified upload: version 0.1.0, build 1014, source `7b03ab2`.
  [Release workflow](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40814036340)
  passed 88 core and 17 build/signing guard tests, compiled the redesigned app
  for Release, and successfully archived, exported and uploaded to Apple.
  Review now uses a horizontal timeline, fixed center marker, compact transport,
  corner zoom controls, and a wrapping camera-preview grid without sideways scrolling.
  HTTPS playback reconciles actual displayed frames with renderer readiness so
  missed notifications cannot indefinitely leave its waiting label on screen.
  Administrator event details include separately saved sub-label/description
  editing with pre-save conflict checks and explicit queued-update confirmation.
  Live includes a manually launched, muted Camera Tour for tent/stand use, with
  readiness-based intervals, pause/previous/next and foreground-only playback.
- No simulator/UI tests or screenshot generation ran during deployment. UI
  acceptance is performed by the owner on the TestFlight phone.
- Verify build 1014's Apple processing, compliance state and internal group
  assignment separately; upload success alone is not tester availability.
  Do not answer legal declarations without the owner's confirmation.
- Physical phone/Duo appearance and live-server acceptance remain unverified;
  passing CI and Apple processing are not proof those device checks passed.

### Pending image-notification release

- The approved pending-backend attempt was build 1015, source `9a8dc2f`,
  [run 40824746991](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40824746991).
  It passed 111 Swift core tests, 29 CI guards, and both profile checks on
  Xcode 27.1, then failed Release compilation before export/upload.
  `CGImageDestinationAddImage` was missing its destination argument; the source
  fix is prepared. Fresh owner approval is required for another native build.
- A separately approved build 1016, source `ac61631`,
  [run 40826319468](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40826319468),
  passed guards/core/profile checks and successfully compiled and signed the
  notification extension. Main-app compilation failed because a catch-bound
  `error` shadowed the published error property during image-session refresh.
  The assignment is corrected to `self.error`. No archive export or upload
  occurred, and another attempt requires fresh owner approval.
- The owner's subsequent **always push** instruction supersedes those historical
  per-attempt approval requirements for standard public-runner app/TestFlight
  fixes and retries. Build 1017 starts from the corrected source `48e4fe7`;
  backend changes, public/external releases and legal declarations remain separate.
- Build 1017, source `48e4fe7`,
  [run 40827387074](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40827387074),
  passed 111 Swift core and 29 CI guard tests, full Release app/NSE compilation,
  signing, archive/export and upload. Apple reports `VALID`,
  `usesNonExemptEncryption=false` and `IN_BETA_TESTING`; the automatic owner group
  includes the build. No legal value was changed by this agent.
- The operator feature wave is build 1018, source `0efe830`,
  [run 40829834017](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40829834017).
  It adds local per-account camera favorites, density/filter choices, matching
  Camera Tour selection, accessibility layout and foreground/manual notification
  support refresh. All 121 core and 30 CI guard tests passed (38 offline Python
  tests locally, including uncommitted experimental-tool tests); full Release
  app/NSE compile/sign/archive/export/upload passed without UI tests.
  Apple reports `VALID`, `usesNonExemptEncryption=false`, `IN_BETA_TESTING`, and
  automatic owner-group inclusion. Phone UI and actual push/image acceptance
  remain owner checks, not inferred from CI.
- Approved NSE signing setup is now complete: App ID
  `com.errantactions.frigatehorizon.NotificationService` and its App Store
  profile were created using the existing distribution certificate. Both live
  profiles passed the shared validator, and only the new extension-profile
  secret was added. Existing main-profile/certificate/upload secrets are unchanged.
- Builds 1017/1018 used the explicitly approved pending-backend override.
  The October 29 verified backend image-ready receipt now matches the client's
  capability/payload/thumbnail/auth/header contract, and
  `APNS_IMAGES_BACKEND_READY=true` is set in `app-store`.
  Future normal builds need no pending-backend override; do not rebuild 1018
  solely for this environment metadata. Its runtime refresh discovers readiness.
- Core and native app/NSE compilation/signing/archive/export/upload now passed
  through build 1018. Phone delivery and real-server interaction remain unverified.
- Local camera-tour refinements add immersive controls, custom timing,
  authenticated motion following, and next-camera decoded-frame preloading.
  Their core contracts and native UI compiled and uploaded in 1017/1018;
  physical-device behavior remains owner acceptance.
- A subsequent Live-grid cleanup removes the separate tile footer and enabled
  badge, keeping camera names as compact video overlays. It is not part of the
  build 1015 source; it shipped successfully in builds 1017 and 1018.
- The operator wave carries forward build 1017's existing cleared
  `usesNonExemptEncryption=false` classification as a real Boolean
  `ITSAppUsesNonExemptEncryption=false` in both app/NSE plists. The pinned
  dependencies and encryption behavior are unchanged (WebRTC remains 156.0.0).
  Reassess this declaration if cryptography/dependencies change. There is no
  generic plist switch for France distribution.
- The approved extension App ID/profile and extension-profile secret were added.
  Native push and verified backend-image readiness flags are true. This app task
  changed no backend deployment, alert rules or provider key and sent no push.
- Phone acceptance remains: install 1018, refresh server support, grant
  notification permission, register, and explicitly opt into Lock Screen images.
  Existing server alert rules remain OFF; app selection does not enable them.
  A no-reference test is text-only. Coordinate a deliberate camera scope and
  separately authorized real push before claiming image receipt/display.

### Full native NVR feature release

Build 1020, source `2ca0686`,
[run 40945180763](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/40945180763),
passed all 219 core tests and 30 CI guards, full app/NSE Release compilation,
signing, archive/export and upload. Apple reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; automatic owner-group
membership is verified. Build 1019 passed the same core suite but failed on
three native compiler issues, corrected before 1020. No UI tests ran.

The binary contains all seven requested features: live PiP, quick evidence,
supported PTZ/PTT, synchronized incident replay, notification actions/quiet hours,
scoped opt-in health alerts and migrated named camera groups. Server-dependent
features are capability gated. The October 30 TrueNAS recovery supersedes the
old instance's image-ready acceptance: do not assume the former image, sessions,
push registrations or capabilities describe the recovered service. Verify its
current baseline before supported Linux HTTP/synthetic-media qualification and
guarded rollout. Historical unknown relay operations must be reconciled through
the approved connection, never replayed or bypassed.

`APNS_IMAGES_BACKEND_READY` is false again pending fresh scoped image/provider
acceptance on the recovered instance. This changes neither the signed binary nor
notification opt-ins. Native app/NSE certificate validation remains intact;
command-line certificate pinning or a browser exception does not qualify an
untrusted/self-signed NAS IP address as a native connection endpoint.

Native feature reads require a real current session; camera-control capability
reads also require access to that camera. PTZ and talkback start/renew require the
current database admin role and camera access, not a forwarded role header.
Talkback release remains same-owner, camera-and-lease-scoped cleanup without
requiring ongoing control permission; it cannot start or renew media.

Permanent export protection adds a mandatory rollback gate. Before advertising
`export_protection` or accepting the first protection write, validate an immutable
guard-compatible fallback image or equivalent tested recovery that preserves
protected export metadata, files and every deletion guard on the upgraded schema.
The image-only `person-images1` release is **not a safe rollback after protection
writes**. Keep protection unavailable on the server, including direct protection
POSTs, until that recovery receipt exists; hiding the native button is insufficient.
Deletion guards must remain active even while new protection writes are disabled.
Never restore an older database or unguarded export API without preserving later
protection records and assets.

The pinned go2rtc owned-consumer extension and Linux binary are prepared for
the backend rollout, with seven portable Go lifecycle tests and 17 portable
backend control/lease tests passing. These are not a substitute for the blocked
Linux API/file/HTTP/SDP validation or real-camera/phone acceptance.
The app binary alone does not enable camera alerts, opt into health delivery,
move a camera, start a microphone, or send an Apple push.

### Native connection recovery

Build 1021, source `d46d30f`,
[run 41015040188](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41015040188),
passed all **230 core tests and 30 CI guards**, full app/NSE Release compilation,
signing, archive/export and upload. Apple build
`5da4d941-12d0-4875-92ce-0daaa67e9dab` is `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; membership in Owner Testing
Auto was verified. No UI or simulator tests ran.

The upload explicitly used `allow_pending_image_backend=true` while
`APNS_IMAGES_BACKEND_READY=false` remained unchanged. This client-only release
does not attest recovered-backend image readiness, enable alerts, change server
configuration or depend on communication with the backend worker.

The connection screen can retry a matching saved server/session after transient
network failures without resending a password. DNS, offline, timeout, certificate,
TLS, authentication and HTTP/proxy errors have distinct recovery guidance.
Settings supports signing in again to the same account without forgetting saved
camera groups or layouts; passwords remain memory-only. The returned account must
match before the new session is stored. Changing accounts still uses the explicit
disconnect flow and its push-cleanup choices.

Returning to the foreground refreshes configuration and account scope. Failures
retain the last configuration with a visible connection warning and the last
successful check time, not a false healthy indicator. Superseded refreshes cannot
restore an old session after disconnect or overwrite a newer sign-in. In-flight
media cleanup can retain its original client until it finishes.

Shared connection diagnostics contain only the category and HTTP/network codes.
They exclude server addresses, accounts, cookies, camera names and raw server
messages. These changes do not bypass certificate checks, retry camera commands,
change backend settings or enable alerts.

### Native adaptive live-quality contract

Manual-profile compatibility source `ba23e88` passed **255 core tests, 30 CI
guards and an unsigned generic iOS device Release build** in
[qualification run 41072962987](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41072962987).
The shared resolver is used by preferred-stream selection and the actual player,
including explicit pins and the user's Auto maximum. The adaptive test class now
has 25 tests; 13 new regressions cover generation-disabled profiles, missing
profiles, disabled cameras, explicit pins/ceilings, delayed frames and renderer
queue pressure.

That source-qualification run performed no signing, simulator/UI tests, installation or TestFlight upload.
`APNS_IMAGES_BACKEND_READY` remained false with no pending-backend override, so
publication was held at that stage. Build 1021 did not contain this fix;
the explicitly requested build 1022 below now includes it.
No accessible real-iPhone measurement tools were available in the Windows
workspace. First-decoded-frame time and real quality transitions are unmeasured,
not inferred from unit tests or compilation.

Earlier initial-ladder source `670fe80` passed **242 core tests, 30 CI guards and an unsigned generic
iOS device Release build** in
[qualification run 41065923427](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41065923427).
Simulator/UI tests, signing, artifact upload and deployment were not run.
This is source qualification, not a TestFlight release or measured camera/network
acceptance; build 1021 was then the last signed release. Backend native-control
source pins and readiness flags were not changed.

The client uses the existing configuration and signaling surfaces, not the
unreleased `/api/native` namespace:

- `GET /api/config`: `cameras[id].live.streams` maps labels to actual stream
  aliases. Optional `live.transcode` supplies `enabled`, `source` and
  `qualities: [{height: Int}]`. The current client does not infer a bitrate cap
  from height or invent a bitrate/resolver endpoint.
- Generated main-derived aliases are `<camera>_transcode_<height>p`, and must
  also appear in `live.streams`. Automatic adaptation requires declared profile
  metadata and at least two advertised eligible aliases. `transcode.enabled`
  controls server-side generation, not availability: explicitly advertised manual
  profiles remain eligible when it is false. No client action enables generation.
  Otherwise playback
  stays on its existing selected stream without an adaptive retry loop.
- HTTPS playback uses authenticated, same-origin
  `/live/mse/api/ws?src=<alias>`, existing `mse` codec negotiation and binary fMP4.
  WebRTC uses `/live/webrtc/api/ws?src=<alias>` and existing offer/candidate
  messages. HTTPS/fMP4 is not an HLS adaptive-bitrate manifest.

Automatic camera detail playback starts at the lowest advertised main-derived
quality of at least 720p, up to the expanded target or the user's explicit Auto
maximum. Manual pins bypass the adaptive plan; removing a profile never silently
substitutes an unadvertised alias or exceeds the selected maximum.
It can step up after 15 seconds of confirmed video no more than one second old,
or down after delivery stalls or a
constrained/expensive network signal. Switches have an eight-second cooldown;
quality reductions block upgrades for 60 seconds, and a session makes at most
two automatic upgrade attempts. A failed upgrade that produces no video falls
back after eight seconds. Decoder-capacity failures may fall back sooner.
HTTPS also observes the renderer's queued-video duration: more than two seconds
of queue sustained for three seconds suppresses upgrades and can trigger a
downshift. This is measured queue pressure, not a claim of end-to-end camera latency.
Only one playback session/decoder is owned at a time; a rendition switch can
briefly interrupt video and is not claimed to be seamless.

Manual stream selections, active/starting PiP and tour preloads remain pinned.
Grid previews keep their existing 720p target. Alias availability and account/
camera scope are rechecked before playback; changing a viewing quality never
changes recording, detection, camera encoder configuration or server settings.
The WebRTC activity observer reads already decoded frames, throttled to four
updates per second, rather than starting an extra decoder or media connection.

This is client-side rendition selection, not control of a fixed stream's encoder
bitrate. Genuine capped-bitrate variants, codec/GOP settings, encoder warmup and
their advertisement remain backend responsibilities and require an agreed
contract plus measurement before making startup or bandwidth improvement claims.
The manually provisioned 720p/1200-kbps and 1080p/2500-kbps server profiles are
selected by their advertised aliases; the app neither hardcodes those bitrate
values nor writes camera, NAS, GPU, detection, recording or notification settings.

Real-iPhone first-decoded-frame time and transition measurements remain separate
acceptance work; source/unit/device-compilation results are not installed-app
measurements. A web streaming deployment does not update the iPhone app binary.

For source qualification without app deployment, manually run the iOS workflow
with `device_build_only=true`, `include_compatibility=false` and
`upload_artifacts=false`. This runs core tests and compiles a generic iOS device
Release build without signing, uploading, simulator tests or UI tests. It does
not alter TestFlight or backend readiness.

### Native live HLS: TestFlight 1022, backend activation separate

The owner explicitly requested TestFlight publication on October 30.
Build **1022**, source `e0c9b00` (qualified implementation `8bcab4b`),
[run 41111808155](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41111808155),
passed all **297 Swift tests and 30 CI guards**, full app/NSE Release compilation,
profile validation, signing, archive/export and upload without errors.
Apple build `91d3b930-9893-417a-a837-2bb350867bdf` is `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto
membership was independently verified.

The existing protected environment approval was used without changing its rules.
The upload explicitly selected `allow_pending_image_backend=true`, keeping
`APNS_IMAGES_BACKEND_READY=false` and its timestamp unchanged. The release does
not attest backend HLS/image activation, enable alerts, alter provider keys,
contact the server worker or change server configuration. No simulator/UI tests
ran. Actual installed-iPhone startup, ABR, Range, audio, live-edge and PiP
acceptance remain pending; HLS is used only when the server opts in and reports
the camera available. Otherwise the existing HTTPS compatibility path remains.

Earlier checklist-completion source `8bcab4b` passed **297 Swift tests, 30 CI guards
and unsigned iOS-device Release compilation** in
[run 41110809370](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41110809370).
This includes eight new 401-routing/live-edge recovery policy tests and the
existing real macOS AVPlayer fixture. It does not claim installed-iPhone,
live-backend seek, audio-continuity or PiP acceptance. That qualification did not
upload to TestFlight or change readiness.

The confirmed v1 alignment in source `e19df50` passed **289 Swift tests,
30 CI guards and an unsigned iOS-device Release build** in
[run 41103722639](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41103722639).
The real macOS AVPlayer fixture now verifies optional master metadata and
authenticated complete-200 origin objects with GET only and no Range/HEAD
dependency. Flat route, query-boundary and distinct 401/403/gateway regressions
passed. This does not qualify real-iPhone Range, latency, ABR transitions or audio.

Earlier initial HLS source `cfff14e` passed **288 Swift core tests and 30 CI guards**, including
authenticated HLS resource/part/range tests and a real macOS AVPlayer test using
the repository's generated fMP4 video fixture. An unsigned generic iOS-device
Release build passed in
[run 41098363504](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41098363504).
This is not a simulator, real-iPhone, deployed-backend or installed-app result.
That qualification left TestFlight publication and all readiness flags unchanged.

`cameras[id].ui.live_hls` is optional and defaults false. Only Automatic viewing
over the HTTPS transport checks `GET /api/{camera}/live/hls/status`; manual
streams, WebRTC and tour preloads retain their original player. The version-1
`ll-hls` response selects the canonical camera-scoped master relative to the API
base. Missing/unsupported status (404/405/410/501), disabled/unavailable status or
an unknown protocol/version uses compatibility HTTPS with a visible notice.
Authentication, TLS, malformed active status and real playback errors fail
explicitly. They do not restart repeatedly or fall back through a weaker path.

The status `renditions[].bitrate` values are video targets in kbps, not measured
master bandwidth. The client reads actual `BANDWIDTH` and optional `RESOLUTION` attributes,
retains eligible advertised variants and audio, and filters the master to the
user's explicit maximum. A temporary `preferredPeakBitRate` uses the lowest
eligible master bandwidth. After decoded video, a playing state and at least one
second of buffer remain healthy for three seconds, the cap is released and
AVPlayer performs native ABR. Low Data Mode/constrained or expensive paths retain
or reapply the lowest cap without replacing the item.

#### Authenticated delivery and ownership

The first custom-scheme resource-loader approach failed the real AVPlayer
fixture before any media segment loaded; it was replaced, not accepted on
compilation alone. AVPlayer now reads ordinary HLS through a private, in-process
adapter bound only to `127.0.0.1` on an ephemeral port. A distinct random cookie
protects each asset; it is never placed in a URL. Tests prove missing-cookie
rejection, refusal on another loopback address, and listener closure on teardown.
There is no third-party relay, home port forwarding or new ATS/TLS exception.

Every remote request remains normal certificate-validated, authenticated HTTPS
to the configured origin and camera's `/api/{camera}/live/hls/` subtree.
Master/child/audio/map/segment/part/preload/report URIs are validated and
rewritten; cross-origin/cross-camera routes, traversal, credentials, fragments,
unexpected queries, keys and steering/variable contracts are rejected.
Only standard `_HLS_msn`, `_HLS_part` and `_HLS_skip` reload queries are allowed.
Backend session values and cookies are not exposed in player URLs or logs.

Ordinary media chunks are streamed from the authenticated HTTPS client to the
local player instead of downloading an entire segment before delivery.
Playlists require bounded validation/rewriting. Version 1 origin requests are
always GET, without Range or HEAD: complete 200 objects are fetched. If AVPlayer
asks the private adapter for HEAD or a bounded byte range, that request is
emulated locally from the complete object; upstream 206 is neither required nor
used. This does not claim end-to-end iPhone Range or latency acceptance.

The existing live session owns the AVPlayer, its layer and its private adapter.
PiP uses that same AVPlayerLayer and account/camera scope; audio and native ABR
continue without creating a second decoder. Talkback retains microphone/audio
ownership. Offscreen/background playback stops unless explicitly retained by
PiP; stop/logout/source changes cancel requests, close the adapter and release
the item. Original streams remain available as explicit pins or compatibility
playback. Recording playback behavior is unchanged.

An HLS 401 now exposes the existing same-account sign-in flow without clearing
the saved session, camera groups or layouts. The notification is accepted only
from the currently active API; camera-denial 403 and gateway failures do not
request reauthentication. Passwords remain memory-only and no login is attempted
without the user's action.

AVPlayer preserves its native live offset. If an already displayed live item
waits without progress for five seconds and is behind/outside its seekable live
window, the app may seek within that same item once, respecting AVPlayer's
recommended offset (or a bounded three-second fallback inside the window).
Paused/healthy/near-edge playback does not trigger a recovery seek. The seek has
an eight-second completion deadline; failed recovery or persistent stalls surface
an error instead of repeatedly rebuilding the item. Explicit Reconnect starts a
fresh item and resets that bounded budget. Audio, quality caps and PiP keep the
same owned AVPlayer during recovery.

#### Confirmed backend version 1 contract

- Master: `/api/{camera}/live/hls/master.m3u8`. It references advertised
  `{height}p/{playlist}` routes. Child playlists reference flat `.m3u8` or `.mp4`
  filenames in that same rendition directory, including audio, init maps,
  parts, segments, preload hints and rendition reports. Names are read from
  playlists, never guessed. `.ts`, `.m4s`, keys and nested child paths are rejected.
- `_HLS_msn` is 0 through Int64.max. `_HLS_part` is 0 through 1,000,000 and
  requires `_HLS_msn`. `_HLS_skip` is `YES` or `v2`. MediaMTX `session` and
  `cookieCheck` parameters are never added or forwarded.
- Origin responses are complete 200 objects; Range/206 and HEAD are not part
  of this backend version. Local AVPlayer handling is described above.
- Master `RESOLUTION`, `CODECS` and `FRAME-RATE` are preserved when supplied.
  If resolution is absent, only the explicitly advertised height-directory
  metadata is used for the height ceiling; width/codec/frame-rate attributes
  are not invented. `BANDWIDTH` remains authoritative for startup capping:
  current 1200/2500-kbps targets advertise 1,876,000/3,631,000 bps. Their
  `AVERAGE-BANDWIDTH` values are configured targets, not measured throughput.
- Each remote request carries the session independently. Status is inspected
  before parsing even if an error body is HTML. 401 is authentication expiry,
  403 is camera access denial, and 5xx gateway/packager failures are not DVR
  logout or compatibility success. The private packager session stays server-side.

The backend is installed but adaptive HLS remains disabled pending activation
and authenticated playback checks. Keep compatibility playback. The remaining
timing detail to confirm is the maximum blocking-reload wait relative to the
client's 25-second request timeout.

Do not enable server features or infer readiness from these fixtures. Real
iPhone first-decoded-frame time, native bitrate transitions under throttling,
LL-HLS timing, uninterrupted audio, PiP restoration and background cleanup remain
separate acceptance requirements. No NAS, packager, recording, GPU/detector,
notification or APNs readiness change was made by the native implementation.

### Native server settings and notification tuning

TestFlight **1023**, source `f48b30a`,
[run 41120215370](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41120215370),
ships these controls under the owner's standing approval. Both the final
[unsigned qualification](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41119665720)
and release passed **319 core tests and 30 CI guards**. The qualification passed
generic iOS-device Release compilation; the release passed full app/NSE
compilation/signing, archive, export and upload. No simulator/UI tests ran.
Apple build `c1b3428d-159c-4a2e-9702-a38dc61cbb6f` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. Existing environment protection and the explicit pending-image-backend
workflow input were retained. `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp are unchanged. No server setting, provider,
registration or alert was changed by preparing this release. Real-iPhone forms,
live-server save/apply and notification receipt remain separate acceptance
checks; no test push or server restart was performed.

The native settings catalog is available to administrators from Settings and
Administration. It uses the running server's `/api/config/schema.json` and
`/api/config`, not hardcoded assumptions about newer backend features. Native
switches, enum pickers, numeric/text/private fields, nested sections, lists and
maps cover the server's published settings, including cameras, recording/
retention, detection, motion/adaptive filtering, objects, review labels/zones,
live viewing, snapshots, audio, integrations and Apple push provider metadata.
Computed fields are read-only; the advanced editor remains for unsupported or
unsafe structures rather than pretending an edit succeeded.

Edits remain local until Review. Only changed fields are sent through the
existing `PUT /api/config/set` body with `requires_restart: 1`; unrelated settings
and credentials are not rewritten. Lists are saved whole, so list edits that
would resend redacted credentials are refused. Inline private-key material,
ambiguous dotted/slashed paths and runtime `enabled_in_config` fields are rejected.
Vehicle/animal labels and required zones remain exact; no category renaming or
opt-out reset is performed.

The saved raw source is held only in memory and checked again before saving;
this is a conservative client conflict check, not an atomic server CAS promise.
The server validates the partial update. Save only does not claim that runtime
settings changed. Save and restart has a second explicit destructive confirmation;
if persistence succeeded but restart cannot be confirmed, that partial outcome
is surfaced without replay. Unsaved-close confirmation and deferred notification
navigation protect drafts. Account/API/role changes invalidate the editor.

Native notifications now link to a setup checklist and running per-camera rules.
The guide separates server APNs provider readiness, effective camera rules,
iOS permission and this installation's registration. Administrator links lead to
native provider/default/camera-notification/review forms. Quiet hours, snooze,
health opt-in and images remain separately capability gated and opt-in.
No provider key is copied into the app; the APNs signing key stays mounted on the
server, distinct from the App Store Connect upload key. No alert, push test or
server setting is enabled merely by opening or refreshing these screens.

Apple's build 1023 device crash report identified a missing environment object
at `NativeSettingsNode.body` while reading the settings store. Settings nodes,
rows, scalar editors and review destinations now require that same store as an
explicit observed-object initializer argument. The root remains its single
state-object owner, preserving drafts and notification-navigation lifetime
across child screens. No settings destination depends on environment lookup for
this store. Three source guards cover explicit observation, every constructor
path and single-root ownership; device compilation checks the required
arguments. These are not a substitute for installed-iPhone navigation acceptance.

The fix shipped in **TestFlight 1024**, source `fa3ef0b`,
[run 41125344409](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41125344409).
The three guards failed against the released dependency wiring before the fix
and passed afterward. Release CI passed **319 core tests and 33 guards**, full
Release app/NSE compilation/signing, archive, export and upload. Apple build
`f336f674-d56c-4955-a2ca-41618eeb2c23` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. No simulator/UI tests ran. Installed-iPhone confirmation remains pending.
The existing protected environment and explicit pending-image-backend input were
retained; `APNS_IMAGES_BACKEND_READY=false` and its October 30 05:27:40Z timestamp
are unchanged. No server, provider, registration or notification changes were
made. This hotfix does not claim to resolve the separately unverified phone
connection/network-path report.

### Navigation simplification

TestFlight **1025**, source `f3c4ecf`,
[run 41147087537](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41147087537),
ships the owner-approved audit implementation. The
[unsigned qualification](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41146317247)
and release both passed **332 core tests and 38 CI guards**. Generic device
Release compilation passed; the release also passed full app/NSE signing,
archive, export and upload. Apple build
`d170daa4-6a6d-4113-960b-8678f8987097` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`, and Owner Testing Auto
contains it. No simulator/UI tests ran. Installed-phone/Duo visual acceptance
remains pending. Existing environment protection and the explicit
pending-image-backend input were retained. `APNS_IMAGES_BACKEND_READY=false`
and its `2026-10-30T05:27:40Z` timestamp are unchanged. No server, provider,
registration or notification changes, production NVR requests or test pushes were
performed by this navigation implementation.

Compact layouts use five primary destinations: **Live, Activity, Recordings,
Library and Settings**. Activity switches between review and event search;
Library switches between exports and protected media. Wide/Duo layouts retain
sidebar shortcuts for search, exports, protected media and administrator tools.
Collapsing a shortcut into compact layout selects the corresponding primary
destination. Activity queries/search text and the library camera filter are
shared across these routes. Administrator controls remain role gated.

Review rows open the timeline directly and return to the same filtered list,
without a selected-detail landing page behind playback. Live camera details
provide a permission-checked recording handoff with the camera, local day and
requested timestamp. Only an indexed range containing that timestamp is
automatically selected; missing footage is not substituted. The standalone
recording browser returns to the originating camera. Inline live/talkback
consumers pause while history or evidence tools cover the camera; PiP ownership
continues to use the existing lifecycle.

Settings is a compact hub for connection/account, this iPhone, server controls
and About. Administration embeds in the existing navigation stack. Notifications
has one hub with distinct server-rule and phone-registration sections. Opening
these pages does not opt in or send pushes. Server settings group schema fields
by task and search schema names/paths, never configuration values or credentials.
Search respects camera scope and reports unsupported/limited branches. Safe
non-null enum/numeric fields edit inline into the same draft; private/nullable
fields retain the dedicated editor. All validation, review, source-conflict
preflight and save/restart confirmations remain mandatory.

Camera mute, history and supported camera controls precede collapsed quality/
connection information. Live tour, incident replay and refresh share a tools
menu; pull-to-refresh remains available. No backend namespace, TLS/auth policy,
recording/detector/provider setting or readiness flag is changed by this pass.
Compact/Duo layout, large-text, keyboard and installed-phone navigation remain
separate acceptance checks; compilation/source guards are not visual validation.

### Live camera order and disabled cameras

TestFlight **1026**, source `77c6e5a`,
[run 41150506353](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41150506353),
ships this client-only change. The
[unsigned qualification](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41150156672)
and release both passed **342 core tests and 42 CI guards**. Generic device
Release compilation and full app/NSE signing/archive/export/upload passed.
Apple build `894dfb1c-4084-4d5f-87ce-b3f26b41de71` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. Existing environment protection and the explicit pending-image-backend
workflow input were retained; `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp are unchanged. No simulator/UI tests or production
NVR operations ran. Actual installed-phone drag/VoiceOver/Duo acceptance remains
pending.

Live now provides a visible **Reorder** button and **Camera view options >
Reorder cameras**. Native drag handles reorder the current dashboard/group;
Save commits the layout locally for this server/account, while Cancel protects
unsaved changes. Favorites-only edits reorder that subset without moving other
saved slots. Custom order takes precedence over favorites-first sorting;
untouched/legacy layouts retain favorites-first behavior. Existing favorites,
groups, density and the `liveDashboard.v2` account namespace are preserved.

Disabled cameras and cameras with `ui.dashboard=false` are excluded from Live,
group selection/counts and tour candidates. Disabled/unavailable saved IDs and
positions remain stored for re-enablement or restored access. New eligible
cameras append in server order; nothing grants camera access. The editor checks
current availability, account scope and layout snapshot before saving, and
previews pause while it is open. The same saved order feeds Camera Tour.

This is client-only: no camera is enabled, and no server/configuration request,
recording, detector, notification/provider or readiness setting is changed.
Disabled cameras remain accessible in the permission-checked recording browser
for historical footage. Installed-iPhone drag/VoiceOver/Duo acceptance remains
separate from core and source-guard qualification.

### Saved server profiles and local addresses

TestFlight **1028**, source `fbad440`,
[run 41170128713](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41170128713),
ships this app-only feature. The final
[unsigned qualification](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41169838606)
and release both passed **358 core tests and 49 CI guards**. Generic device
Release compilation and full app/NSE signing/archive/export/upload passed.
Apple build `29133ad3-2253-4a8c-948a-26eee4bb2860` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. Existing environment protection and the explicit pending-image-backend
input were retained; `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp are unchanged. No simulator/UI tests, production
NVR operations, provider actions or test pushes were performed.
Real-iPhone Keychain migration, profile switching, DNS/LAN reachability, IP
certificate and Duo acceptance remain pending; this does not attest recovery
of the separately reported phone connection issue.

Predecessor candidate **1027**,
[run 41169563121](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41169563121),
was canceled to add the selected-offline-profile notification cleanup guard.
Its log records cancellation before archive/export/upload success; build 1027
was not listed in the bounded Apple checks. It is not the delivered update.

**Server profiles** is available before sign-in and under **Settings >
Connection and account**. Users can add, rename, edit and delete multiple
profiles with primary and optional local HTTPS addresses. The current legacy
HTTPS connection migrates without saving its password. Existing manual HTTP
connections are not upgraded or silently converted; new saved profiles require
HTTPS. Editing active addresses or deleting an active profile requires
disconnecting first.

The local address accepts a full HTTPS URL or a bare RFC1918/ULA private IP.
Bare IPs inherit the primary port/proxy base path; full URLs retain their own.
**Find private IP from hostname** resolves only the configured hostname using
the phone's current DNS. It neither scans the LAN nor assumes a backend discovery
API. Candidates are suggestions, not identity or reachability attestations.
There is no automatic route selection, fallback, certificate exception, Host/SNI
override, port forwarding or new ATS exception. An HTTPS IP requires a trusted
IP-matching certificate; otherwise use a trusted hostname that resolves locally.
Local Network permission and a working network path are still required.

Defaults contain only validated profile metadata and the selected route. Profile
sessions live separately in device-only Keychain storage, keyed by profile UUID
and exact address (scheme/host/port/base path), never copied between endpoints.
Restore rechecks record scope and the previously authenticated username; expired
or denied sessions surface through existing reauthentication. Passwords are
never persisted or replayed. Editing endpoints clears that profile's old
sessions; deletion clears only that profile's logins. Explicit reset is provided
for malformed local metadata. Camera layouts stay address/account scoped.
Editing or deleting the selected offline profile also stops local notification/
image access and retains any outstanding server-registration cleanup obligation;
it does not silently allow alerts to be enabled against a different binding.

Switching requires confirmation when leaving an active account or pending push
binding. Playback/PiP and local camera controls stop, while owned lease cleanup
can finish with its original client. Existing device-registration cleanup runs
before switching; an unavailable old server requires a second, explicit
without-cleanup choice. Outstanding cleanup is not represented as success.
Push/images are not enabled for the new profile automatically. The switch
generation prevents stale requests from reactivating the previous account.
Profile selection without a cached login returns to sign-in; it does not claim
the server is connected. No provider, readiness, recording or NAS setting is
changed by adding a profile.

### Explicit HLS-only servers

TestFlight **1029**, source `35c523f`,
[run 41175528599](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41175528599),
ships this explicit client mode after the owner reported an "HS-only" server
(interpreted as HLS-only, not a new TLS policy). Final
[unsigned qualification](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41175296036)
and release both passed **366 core tests and 53 CI guards**. Generic device
Release compilation and full app/NSE signing/archive/export/upload passed.
Apple build `149f478e-83d5-4c73-acf6-7e98cb1beda1` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. Existing environment protection and the explicit pending-image-backend
input were retained; `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp are unchanged. No simulator/UI tests, production
NVR operations, provider actions or test pushes were performed. Actual server
status/master compatibility and iPhone first-frame/audio/ABR/PiP acceptance
remain pending; this is not a claim that the reported phone video failure was
independently reproduced or resolved on the installed app.

For a server that has removed WebSocket/WebRTC live playback, open a camera's
**Quality and connection > Transport > HLS-only (AVPlayer over HTTPS)**, then
Reconnect. This explicit client choice checks the existing camera-scoped HLS
status even if older configuration lacks `ui.live_hls`, a legacy manual stream
was selected, or the compatibility stream map is empty. The legacy stream choice
is retained for other modes, not silently mapped to an invented HLS variant.
When its height is explicitly advertised by existing profile metadata, a manual
pin also seeds the HLS ceiling without exceeding a tighter selected maximum.
Unknown legacy aliases do not invent a height; users choose the HLS maximum.
HLS quality ceilings come from advertised status renditions; the master
playlist's actual bandwidth remains authoritative for startup/native ABR.

HLS-only never falls through to WebSocket or ICE when status is unavailable,
unsupported or playback fails. Errors remain visible and recovery stays bounded.
The existing automatic HTTPS mode keeps its camera opt-in, automatic-stream
gate and supported compatibility fallback, preserving older servers and
explicit legacy pins. Transport choice remains the existing local app
preference; no server feature flag or transport is re-enabled.

Retained HLS PiP and return-to-app honor an explicit HLS-only choice without
requiring the legacy camera flag, while still checking API/account identity,
camera permission and enabled state. TLS/origin, resource path/query, cookies,
401 reauthentication and 403 camera denial are unchanged. This assumes the
previously published v1 `ll-hls` status/master/child-route contract; a different
server contract requires an owner-provided sanitized status/playlist sample,
not weaker validation. Real-iPhone first frame, audio, throttled ABR and PiP
acceptance remain separate.

### HLS-only viewing integration (current behavior)

**Final delivery: TestFlight 1032**, source `acaff67`,
[run 41258930204](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41258930204).
Apple build `49b969d4-fd57-42f1-82b9-1981c4a3ad5e` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. This supersedes intermediate uploads 1030 (initial integration) and 1031
(API-path cookie bridge) with native scroll-visibility shutdown for grid tiles.
Those uploads succeeded; they are not described as canceled or device-qualified.

Final validation:

| Command/check on GitHub macOS runners | Result |
| --- | --- |
| `python3 -m unittest discover -s tools/tests` | 61 CI guards passed |
| `swift test` | 379 tests, 0 failures |
| `testRealAVPlayerLoadsAuthenticatedFixtureInitAndSegment` | Passed in 0.715 s in the release run; fixture duration is not iPhone startup latency |
| Generic iOS-device Release compilation | Passed in [qualification 41258707881](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41258707881) |
| Protected TestFlight workflow: app/NSE Release compilation/signing, archive, export, upload | All passed on final source |
| Simulator/UI tests | Not run, per owner instruction |
| Physical-iPhone and production-server playback | Not performed; acceptance remains blocked on device/log access |

The unsigned device command was:

```sh
xcodebuild \
  -project FrigateHorizon.xcodeproj \
  -scheme FrigateHorizon \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The signed release used the unchanged protected `testflight.yml` workflow and
its existing `.github/scripts/testflight.sh`, with explicit
`confirm_upload=true` and `allow_pending_image_backend=true`.
`APNS_IMAGES_BACKEND_READY=false` and its `2026-10-30T05:27:40Z` timestamp are
unchanged. No release protection, profile validator or NSE requirement was
removed. Early qualification runs caught async declaration and AVKit actor
scope errors; they were corrected before successful native/signing checks.
The API-cookie and per-resource auth regressions are discovered XCTest methods,
not nested unused helpers.

No confirmed server-contract defect was diagnosed. Remaining contract/device
qualification includes native 4K's changing `PART-TARGET`, authenticated VOD/
SD availability and supported login cookie scope; an API-only cookie cannot be
broadened to make VOD work. No real iPhone was available to collect the required
4K playlists, physical playback metrics or native error/access logs. Do not
label this missing acceptance evidence as an authentication or packager fault.

This supersedes the earlier optional/explicit HLS transport sections. All live
viewing now uses AVPlayer HLS regardless of saved WebRTC/compatibility choices
or legacy `ui.live_hls` flags. No MSE/WebRTC/JSMpeg viewing player or transport
fallback remains. The legacy WebRTC library is retained only for dormant
talkback cleanup code; talkback controls are hidden in this release. Authorized
PTZ and notification permissions remain unchanged.

The configured server root builds an API base ending `/api/`; the status
playlist resolves against that base. Live master selection uses only advertised
heights: tiles pin the lowest available rung and request `audio=false`; full
camera Auto uses `max_height` when capped, and exact quality uses `height`.
4K is offered only when 2160p is advertised. Low Data Mode caps at 720p;
ordinary cellular use is not itself Data Saver. Native AVPlayer throughput/
buffering controls ABR after the startup bandwidth cap releases.

`warm_max_height` and LL-HLS query strings survive URI rewriting unchanged.
Live routes remain camera-scoped with strict private-query rejection, bounded
reload values and full HTTP-200 MP4 loading. No filenames or media timestamps
are constructed, persisted or rebased. VOD and camera-SD use separate scoped
policies, not live-prefix substitution. Viewing uses `/vod/` recording/event/
export/preview HLS; downloads continue using original files. Camera-SD
capability/search/session operations were verified against existing local
server source, not a production RPC; session IDs form the documented HLS route,
and leaving issues the existing DELETE with closure-result validation.

The existing in-process AVPlayer adapter remains bound to loopback only with an
ephemeral per-asset cookie passed through public `AVURLAssetHTTPCookiesKey`.
It is not a LAN/external relay or an exposed proxy. Every remote playlist,
audio/init/segment/part request uses a private ephemeral cookie-authenticated
URLSession with normal HTTPS/origin/path validation and no shared media cache.
It translates local Range/HEAD demands from complete authenticated origin GETs,
without requiring live 206/HEAD support. VOD types/routes are validated
independently. No undocumented AVFoundation header key, credential-bearing URL,
TLS exception, SNI override or direct camera/packager address is used.
The app's cookie bridge retains same-host API-path-scoped cookies as well as root
cookies instead of looking up only the server-root path. Original domain/path/
secure/expiry attributes are not broadened. An API-only cookie consequently
cannot authenticate `/vod/`; that requires the supported login to issue a cookie
scoped for VOD too, and is not worked around by rewriting the cookie path.

401 presents the shared sign-in flow without refresh storms; 403 stops with
camera-denial guidance. A rotated 404 rebuilds from status/master once, never an
unbounded persisted-child retry. Generic VOD also has one fresh-master retry.
Inactive assets cancel loading and close adapters, including backgrounded
recording players unless intentionally owning PiP. Server producer shutdown
may lag the final request by up to 60 seconds. Player metric sharing includes
first decoded-frame latency, observed/indicated bitrate, stall count and decoded
resolution transitions, not URLs/cookies/account identifiers.
Grid consumers additionally follow native scroll-visibility callbacks (one
percent visible threshold); lazy-grid prefetch/retention alone does not grant
playback ownership. Camera detail and explicit tour viewers keep their separate
foreground/PiP ownership rather than depending on a grid scroll container.

Notification support/auth refresh first reads the existing installation's
`camera_ids`. Registration renewal uses the confirmed value, preserving
`null` (all allowed), `[]` (explicit opt-out) and specific selections. Missing
or malformed metadata blocks renewal rather than defaulting to all or empty.
The screen shows actual server choices; edits require the user's explicit
save. Token renewal re-reads current choices unless an explicit save is pending.
Permission changes do not truncate the draft into an empty registration.
Confidence policy, quiet-hours/health preferences and private-photo opt-in are
not reset. No current device registration was read or written during this
source task, and no notification test was sent.

Recorded-media PiP retains the owning HLS asset until PiP ends; offscreen
non-PiP assets stop. Camera-SD playback deliberately has no background PiP:
leaving closes the server session as required, and closure failures surface at
the app level. A mute change updates the retained live selection without
restarting the player. If Low Data Mode becomes active during a pinned 4K PiP
session with no low rung, playback stops with explicit quality guidance rather
than ignoring the data cap.

Real-iPhone acceptance remains required: cold start/audio sync, actual decoded
720/1080/4K, Auto under throttling, idle/resume, PiP, grid resource shutdown,
local/remote recordings and camera-SD closure. In particular, changing native-4K
`PART-TARGET` values are preserved verbatim in fixtures, but native AVPlayer
tolerance has not been measured on a physical iPhone here. If it rejects the
packager's part-duration changes, collect the affected playlists plus
AVPlayer error/access logs and treat it as a packager blocker, not auth failure
or justification for another transport. No production NVR/settings/cameras,
provider flags or other agent was touched.

### Reliable HLS startup and multi-camera tuning

**TestFlight 1033**, source `fbdd96c`,
[release 41266910268](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41266910268),
is processed for Owner Testing Auto. Apple build
`637617d7-608d-4bf0-aab9-c9d3da663504` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; automatic group membership
was independently checked.

Exact final checks:

| Command/check | Result |
| --- | --- |
| `swift test` | 391 tests, 0 failures |
| `python3 -m unittest discover -s tools/tests` | 66 CI guards passed |
| Generic iOS-device Release compilation | Passed in [qualification 41266635808](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41266635808) |
| Three concurrent authenticated macOS AVPlayer fixture players | All reached ready and fetched each camera's init/media; total release test duration 1.782 s, not first-frame latency |
| Per-stage network instrumentation fixture | Passed with 30-ms injected fetch delay and elapsed/first-body assertions >=20 ms; total release test duration 0.464 s, not phone/server latency |
| Final app/NSE Release compilation/signing, archive, export and upload | All passed on final source |
| Simulator/UI tests | Not run, per owner instruction |
| Physical iPhone/production startup, stalls, dropped frames and 4K parts | Not measured; no device/control/log access available |

The unsigned device command was:

```sh
xcodebuild \
  -project FrigateHorizon.xcodeproj \
  -scheme FrigateHorizon \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Final signing/upload used the existing protected `testflight.yml` workflow and
`.github/scripts/testflight.sh` with explicit `confirm_upload=true` and
`allow_pending_image_backend=true`. No environment protection or profile/NSE
requirement was weakened. `APNS_IMAGES_BACKEND_READY=false` and its
`2026-10-30T05:27:40Z` timestamp are unchanged. No server setting, camera,
recording, storage/provider configuration, live device registration or test
notification was changed by this source task; the server agent was not contacted.

No confirmed server packaging defect was diagnosed. Native-iPhone tolerance of
changing 4K part durations remains a physical-device/packager qualification
blocker. The changing-target fixture only proves that the client preserves and
records the evidence; it does not qualify iPhone decoding or playback.

The current tuning prioritizes a fast first displayed frame followed by stable
buffering, not minimum live latency. AVPlayer starts without its automatic
stall-wait gate, then enables that gate after decoded video appears. Requested
forward buffers are three seconds for tiles and six for full-camera playback,
with a six-second live-offset preference; original rendition clocks are never
rebased. The startup bitrate cap still uses master `BANDWIDTH` in bits/second.
It releases after the healthy-buffer interval, or after eight seconds of
continuous decoded/playing video with a short LL-HLS buffer. Low Data Mode
remains an explicit cap, not a reason to hold Auto low on ordinary cellular.

Tiles ignore full-camera exact pins, force audio off and select their lowest
advertised rung. Equivalent resolved master requests reuse the existing player,
including unchanged status/config refreshes. Native scroll visibility and
foreground eligibility still release unused assets, while intentional PiP
retains its owning session. Resolution badges are removed; advertised quality
controls, fullscreen and shareable playback diagnostics remain.

Transient network/stall failures and HTTP 404/408/429/500/502/503/504 rebuild
status and master at most twice. Backoff starts at one then three seconds plus
bounded jitter, with a shared 750-ms recovery-slot spacing so a failed grid does
not reconnect every camera at once. Cancellation during backoff cannot reopen a
consumer. 401 requests the shared sign-in UI once; 403, certificate failures and
unrecognized packaging/decoding errors do not enter a retry or transport loop.
Exhaustion is explicit and offers manual reconnect.
An AVPlayer-closing loopback response during ABR/seek is scoped to that request;
it cancels its origin consumer without failing the entire camera. This only
handles local response writes to the player. Origin HTTP/auth/TLS, playlist and
packager errors still propagate through the normal failure/recovery policy.

Diagnostics separately measure status request duration, first master request,
first child playlist and advertised init-map request durations (including first
body-byte timing), AVPlayer readiness, and first displayed frame since that
attempt began. They include access-log observed/indicated bitrate, stalls,
dropped video frames, numeric AVPlayer error codes and the observed sequence of
`PART-TARGET` values. No URI, credential, camera name or private packager session
is included. Rotating init names are classified from `EXT-X-MAP`, not guessed.
Diagnostic publications are throttled to once per second except first-frame/
failure milestones, avoiding unnecessary grid redraws.
Unavailable access/error logs or invalid bitrate samples are reported as
**not observed**, never substituted with zero stalls or dropped frames.
Use **long-press tile > Share playback metrics** for grid diagnostics, or the
full-camera **Playback metrics** control after a frame or error appears.

Notification attachment on an equivalent API/account updates authorization for
private images without re-registering or resetting camera drafts. Auth renewal
waits for an in-flight old registration to finish before reading current server
choices, preventing a stale GET/renewal from undoing that explicit save. Missing
installation metadata is shown as unregistered/unknown and still blocks implicit
renewal; `camera_ids: []` remains an opt-out. Confidence, photo and original-
quality download behavior are unchanged. No test push or server operation is
performed by qualification.

Actual phone acceptance is still required: simultaneous tiles, cold/warm first-
frame stage reports, switching, Auto under throttling, pinned native 4K/audio,
idle/resume, background/PiP and expired sessions. Tests with injected network
delay establish instrumentation/recovery behavior, not real server or iPhone
latency. Changing 4K `PART-TARGET` values are preserved and reported, not fixed
client-side or disguised as authentication failure. No physical iPhone is
available here to qualify native tolerance or collect production playlists;
that remains an explicit device/packager acceptance blocker, not a diagnosed
server defect.

### Upcoming-backend WebRTC-only delivery

TestFlight **1034**, source `7bb4ab9`,
[run 41290042530](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41290042530),
passed **336 Core contract tests, zero failures, and 61 CI guards**. Full
Release app/NSE compilation/signing, archive, export and upload succeeded.
Apple build `6c282cfd-8b0c-478a-a664-235b58b42fdc` reports `VALID`,
`usesNonExemptEncryption=false` and `IN_BETA_TESTING`; Owner Testing Auto contains
it. The tests include contract doubles, not actual OME/relay/recorded frames.
Obsolete HLS fixtures were removed, so counts should not be compared directly
to the previous HLS suite.

[Qualification 41289772435](https://github.com/ErrantActions/frigate-horizon-iphone/actions/runs/41289772435)
passed the same Core/guard suite and generic iOS-device Release compilation,
including the maintained WebRTC 156 SDK, receive-only peer, sample-buffer PiP
host and localized readiness states. Final same-account cleanup changes were
also compiled and signed by the release workflow. An initial declaration-scope
compiler failure was fixed before successful checks.

The owner explicitly approved autonomous TestFlight delivery of this upcoming-
backend client. Existing protected environment approval and the explicit
pending-image-backend input were retained; `APNS_IMAGES_BACKEND_READY=false`
and its `2026-10-30T05:27:40Z` timestamp are unchanged. No profile/NSE gate was
removed. No simulator/UI tests, server deployment/settings/camera changes,
server-agent contact or test notifications were performed.

**This is not a production playback qualification.** Per the owner's contract,
the new live integration is not deployed and recorded adaptation/control APIs
are undefined. The current HLS deployment therefore gets an explicit upgrade
state in this build. Actual grid/detail/recorded frames, cold/warm startup, Auto,
Data Saver, audio, PiP, LAN/cellular/forced relay, long-lived TURN credentials,
load/cleanup and server original-file hash/length evidence remain blocked.
Recorded endpoint/seek/frame-epoch DTOs are proposals only, documented in
[WEBRTC-VIEWING.md](WEBRTC-VIEWING.md); no live endpoint is used as VOD.

### Automatic internal tester distribution

Use **Owner Testing Auto**, the internal automatic-distribution group created
on October 29, 2026. Its ID is `2e555dfe-174b-42b5-8b03-83519d7f2fd9`.
Apple API verification confirmed `hasAccessToAllBuilds=true` and exactly the
same single owner tester as the original group. The Settings page confirms
**Automatic for Xcode Builds**.

The original manual **Owner Testing** group is preserved. **Family** is a
separate external group and was not changed or given additional builds/testers.
Future eligible uploads reach the automatic internal group after processing
and export compliance are satisfied; this does not bypass Apple's external
testing review or authorize another native build.

## Official references

Security hardening on October 28 also pins Actions to immutable commits,
disables persisted checkout credentials, restricts signing-file permissions,
and prevents the signing helper from reconfiguring an existing environment.
Previous signing logs and run records are not part of this public repository.

- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
- [App Store Connect API access and keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Apple-supported build upload tools](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple role permissions](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions)
- [GitHub CLI authentication](https://cli.github.com/manual/gh_auth_login)
- [GitHub environment secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions)
