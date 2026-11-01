# Native Apple push setup

Native notifications use Apple's Push Notification service (APNs), not Safari
web push. The app talks directly to your Horizon server; that server sends
alerts to Apple. This feature is **off by default** on both sides.

## Current status

The October 30 backend recovery moved Frigate to TrueNAS with fresh sessions.
The recovery handoff records that push registrations and the old signing secret
were not migrated, and notifications/APNs were paused. Do not treat restored
browser access or recordings as proof of native push or image readiness.
The app-store environment now has `APNS_IMAGES_BACKEND_READY=false` until the
recovered instance passes the scoped image/provider checks again. No provider
key, notification opt-in or backend setting was changed by resetting this flag.

Use the verified HTTPS hostname and sign in again when the old session is
rejected. Native app/NSE requests retain normal certificate validation;
successful command-line certificate pinning or a browser certificate exception
does not make a self-signed NAS IP endpoint trusted by the iPhone.

### Historical image-ready deployment

Before the recovery, the APNs backend was deployed with production provider
credentials, `server_id=home-nvr`, and topic `com.errantactions.frigatehorizon`.
Its main App Store profile had production push rights. No devices were
automatically subscribed, and existing global/camera notification rules remained
disabled.
The October 29 image-ready receipt records the deployed
`frigate-horizon:person-images1` image, verified `image_notifications: true`,
mutable-content alerts, and the protected installation-scoped image service.
Its validation passed 205 application/API/image/auth/browser/inference/review
tests on Linux Python 3.11 and 38 core/lease tests on Python 3.13.18. This is not
full application qualification on Python 3.13. All ten recorders progressed;
recording gaps and recovery details remain in the backend release handoff.

### Native binary and signing

The next TestFlight build **must support opt-in images**. Local source now adds
a Notification Service Extension (NSE), authenticated image downloading,
dedicated shared-Keychain state, and dual-profile signing guards. Build 1034
passed 336 core and 61 CI guard tests, full Release app/NSE compilation and signing,
archive/export/upload. Apple reports valid processing, cleared export compliance
and internal beta testing; Owner Testing Auto includes the build.
Actual phone APNs/image delivery remains unverified.
Build 1034 changes viewing to the upcoming WebRTC-only backend and removes HLS
viewing. Missing live support and undefined recorded support show upgrade states.
Notification camera choices, confidence/photo policy and device registration
are independent of this discovery; video startup does not register or reset
this installation. Existing original downloads and the NSE remain intact.

The approved extension App ID and App Store profile are now created, using the
existing distribution certificate. Both live profiles passed the dual-profile
validator, and only `NOTIFICATION_SERVICE_PROFILE_BASE64` was added to GitHub.
The main profile, certificate, upload credentials, and server provider key were
not replaced. A secure local extension-profile copy was verified against Apple.
Whole-app/NSE signing and export passed through build 1034.

Builds 1017/1018 were explicitly uploaded before backend readiness using
`allow_pending_image_backend=true`. Builds 1021/1022/1023/1024/1025/1026/1028/1029/1030/1031/1032/1033/1034 used the same explicit
workflow input after recovery for native connection/live HLS improvements and
native server settings/notification setup, including the settings navigation fix;
the image-ready variable remained false. Build 1022 was explicitly requested by
the owner. Build 1023 followed the standing approval to ship qualified native
updates and is processed for automatic internal testing. Its setup guide does
not enable server notifications or register a phone automatically.
Build 1024 fixes the settings-store environment lookup crash reported on 1023
and is also available to Owner Testing Auto. No installed-phone notification or
settings-navigation acceptance is inferred from compilation or distribution.
Build 1025 ships the approved navigation pass: Settings has one Notifications
hub, with server rules separate from phone registration, and Activity/Library
consolidate the compact navigation. It is processed for Owner Testing Auto;
the release did not enable notifications or change any server setting.
Build 1026 adds local Live camera drag ordering and hides server-disabled cameras
from Live/groups/tours without changing historical access. It is also available
to Owner Testing Auto; notification/provider settings and readiness remain
unchanged.
Build 1028 adds named server profiles with primary/local HTTPS addresses,
endpoint-isolated Keychain sessions and explicit switching. Selected offline
profile edit/delete also stops local delivery and preserves outstanding
registration cleanup. It is processed for Owner Testing Auto. Candidate 1027
was canceled before archive/upload to include that final cleanup guard and was
not listed by Apple on the bounded reconciliation checks.
Build 1029 adds an explicit AVPlayer HLS-only transport for servers that no
longer provide compatibility WebSocket/WebRTC video. It is processed for Owner
Testing Auto. This client choice does not activate backend HLS or change any
notification/provider/readiness setting; actual iPhone live playback remains a
separate check.
Build 1032 is the final HLS-only integration update (superseding intermediate
1030/1031). It also reads this installation's actual server camera selection
before renewal. `camera_ids: []` remains an explicit opt-out; unknown metadata
blocks renewal. Opening streams, refreshing authentication or checking support
must not replace that list with local defaults. Settings > Notifications shows
the server selection and lets the user explicitly save different camera choices.
No registration or test push was performed while preparing this release.
Confidence/quiet-hours/health and private-photo policies are not reset.
Build 1033 additionally avoids re-registration on equivalent API/account
attachment and waits for an in-flight registration before reading choices after
auth renewal. This prevents a stale renewal read from undoing a user's explicit
save. Missing installation metadata is shown as unregistered/unknown rather
than healthy, and still cannot cause implicit subscription or opt-out.
No live installation was changed or test notification sent during this work.
The October 29 image-ready receipt allowed
`APNS_IMAGES_BACKEND_READY=true`; the October 30 recovery invalidates that
attestation for the new instance, so the variable is false again. Reverify the
backend contract before restoring it; do not infer readiness from service uptime.
The signed NSE and production push profiles remain
mandatory. Images still require explicit local opt-in. Build 1018 adds foreground/manual support refresh
and pull-to-refresh in notification settings, without restarting the app.
Image opt-out stays available during support checks. The owner grants standing approval to push app fixes
and retry TestFlight on standard public runners. This does not authorize backend
deployment, public/external releases, legal declarations, or a real push.

## 1. Prepare and validate the backend

### Native enable-and-tune flow

On the phone, open **Settings > Notifications**, refresh server support,
choose cameras, and select **Enable on this iPhone**. Allow iOS permission;
if previously denied, use **iOS notification permissions**. Registration alone
does not enable camera alert rules. Images are a separate Lock Screen opt-in.

The native **Provider, camera rules and cooldowns** page separates:

1. **Server provider:** an administrator configures `apns.enabled`, the stable
   server identifier, app topic, public Apple team/key IDs and the mounted APNs
   private-key file path. Use an APNs provider key, not the upload key. Never
   paste or upload its contents into the app.
2. **Server rules:** intended cameras need their effective notification rule
   enabled. Tune exact review alert/detection labels, required zones and camera
   cooldowns in native server settings. Global cooldown also applies; camera
   opt-outs and suspension still matter. Detection-only review items are not a
   guarantee of push delivery.
3. **Apply deliberately:** review the draft, validate/save and explicitly request
   a restart if needed. The app does not silently apply or restart. Refresh
   support afterward and verify the provider is reported enabled.
4. **This phone:** enable/renew this installation, save camera choices, and
   optionally enable images or supported per-device quiet hours/snooze/health.
   iOS Focus, summary, sound and preview choices can affect presentation.

If provider support says unavailable, phone permission cannot repair it.
Unavailable device-preference capabilities are shown as such, never assumed.
The real test-push button retains its separate confirmation; no push is sent by
setup, schema loading, validation tests or app release preparation.

Server profiles keep separate saved logins for each address. Switching stops
local notification/image access and requests the old installation's cleanup
when needed; unreachable cleanup requires an explicit second confirmation.
It does not enable alerts on the new profile. Return to the old profile/account
to finish outstanding cleanup before enabling notifications elsewhere. Changing
addresses is not permission to copy image credentials or bypass certificate
checks; local HTTPS IPs still need trusted IP-matching certificates.

### Backend qualification

The companion implementation lives in the Horizon server repository. Its
historical image-ready handoff confirmed the exact route, response headers, session
and current database authorization, installation/camera scope and post-render
revocation checks match build 1018. Repeat these checks on the recovered instance.
No new app build is needed for enablement if the verified contract is unchanged.
Backend readiness is not proof of phone receipt/display. Future server changes
must preserve this contract and unrelated work.

Before deploying on a supported Linux/Python environment:

1. Run the APNs and existing browser-notification/API/config regression suites.
2. Verify migration `045_add_native_push_devices.py` against a database copy.
   It adds the separate user `native_push_devices` JSON field and leaves
   browser notification subscriptions alone. Back up the real database before
   any approved migration/deployment.
3. Generate API documentation using `generate_api_auth_spec.py`, then run its
   `--check` mode. Regenerate configuration translations using
   `generate_config_translations.py`. Review generated differences; never
   hand-edit generated files to bypass the check.
4. Verify the default-disabled configuration preserves browser push behavior.

The native endpoints, relative to the existing API base, are:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/notifications/apns` | Nonsecret provider metadata |
| GET | `/notifications/apns/devices` | Your installation metadata, without device tokens |
| POST | `/notifications/apns/register` | Register/renew this installation and camera choices |
| DELETE | `/notifications/apns/register/{installation_id}` | Remove your installation |
| POST | `/notifications/apns/test` | Send a test only to your registered installation |
| GET | `/notifications/apns/thumbnail/{installation_id}/{kind}/{identifier}?height=360` | Required protected image service; verify deployment before enabling images |

Native authentication and an actual user account are required. Registration
cannot choose another username, topic, provider URL, or credentials.

### Required image-service contract

- Capabilities advertise `image_notifications: true` only when image support
  is actually available. Eligible alerts include `aps["mutable-content"]=1`.
- Preserve `aps`, `server_id`, `kind`, and `identifier` (optional only for test).
  Never add image bytes, server/media/destination URLs, credentials, cookies,
  or private keys to APNs.
- The protected image endpoint accepts event/review/camera references, not
  arbitrary paths or URLs. It returns image bytes, a matching JPEG/PNG/WebP
  `Content-Type`, resolved camera ID in `X-Frigate-Camera`, and
  `Cache-Control: private, no-store`. No redirects or public thumbnails.
- Before returning media, verify current database-backed account/role/session
  validity, registered installation ownership, resolved camera permission, and
  the installation's current camera selection. A stale JWT role or a fresh
  `/profile` response alone is insufficient.
- Deny revoked/deleted/unregistered/cross-account installations. An empty
  camera selection permits no camera images. Camera references represent the
  latest preview, not necessarily the incident timestamp.
- A no-reference test remains text-only. Preserve existing browser push and
  disabled notification rules; app camera selection is an additional filter,
  not an override.

The client fails closed if this service/capability is unavailable. It never
falls back to legacy media URLs. Set `APNS_IMAGES_BACKEND_READY=true` only
after separately approved, verified deployment.

## 2. Preserve the separate APNs provider key

The current NVR already has a production-only, Horizon-topic-specific provider
key. Do not recreate, replace, revoke, or copy it to GitHub/the app. The following
setup guidance applies only to a separately approved new-server setup.

In the correct Apple Developer team, create a key with APNs permission suitable
for this app and its required environments. Record its key ID and the team ID.
Download the `.p8` once and store it outside source control.

**This is not the App Store Connect upload key.** Keep it out of GitHub source,
the app bundle, chat, logs, and build artifacts. Do not revoke unrelated keys.
Mount it read-only into the NVR and restrict access to the service account.

## 3. Enable the server deliberately

Example server configuration, after credentials and the key mount are ready:

```yaml
notifications:
  enabled: true
apns:
  enabled: true
  server_id: home-nvr
  topic: com.errantactions.frigatehorizon
  team_id: "{FRIGATE_APNS_TEAM_ID}"
  key_id: "{FRIGATE_APNS_KEY_ID}"
  private_key_file: "/config/secrets/apns/AuthKey_EXAMPLE.p8"
  include_details: false
```

Set the `FRIGATE_` environment values to the public Apple identifiers, not the
private key contents. Enable native server authentication; enable only owner-approved
camera notification rules. `server_id` must be stable and unique per NVR.
Do not reuse it for unrelated servers.

Restart Horizon after an approved provider/credential configuration change.
The notification worker creates its APNs transport at startup. Saving raw
configuration without restarting is not proof the running worker changed.
Allow outbound trusted TLS/HTTP2 to Apple's production and sandbox APNs hosts.

Generic lock-screen text is the default. Camera/event routing identifiers still
go to Apple. `include_details: true` additionally exposes titles/descriptions
to Apple and lock-screen viewers; enable it only intentionally. Media, server
URLs, session cookies, passwords, and provider keys are not in the push payload.
Device tokens are server-side personal data; protect database backups.

## 4. Prepare the Apple App ID and signing profile

1. Reuse the main App ID `com.errantactions.frigatehorizon`, team `QM3794NUZS`,
   its enabled Push Notifications capability, and refreshed App Store profile.
   The existing `PROVISIONING_PROFILE_BASE64` was already replaced. Do not
   overwrite it with an older local profile lacking production push rights.
2. Obtain approval before creating the extension App ID
   `com.errantactions.frigatehorizon.NotificationService` and App Store profile.
   Reuse the same distribution certificate; no new APNs key is needed.
3. Both profiles must allow the dedicated Keychain group
   `$(AppIdentifierPrefix)com.errantactions.frigatehorizon.notificationImages`.
   The app retains its original default group first; the NSE gets only the
   dedicated group. No filesystem App Group is required.
4. Upload the extension profile securely as the separate `app-store` secret
   `NOTIFICATION_SERVICE_PROFILE_BASE64`. Do not re-upload or replace the
   existing certificate/upload credentials. Never paste secret values in chat.
5. After approval, set `ENABLE_NATIVE_PUSH=true` and, only after backend image
   verification, `APNS_IMAGES_BACKEND_READY=true`. The early guard requires both
   profiles, production APS on the app, matching team/bundle/prefix, compatible
   Keychain groups, dates, App Store type, and the same distribution certificate.
6. If the owner explicitly approves uploading the image-capable app ahead of
   backend deployment, dispatch with `allow_pending_image_backend=true` while
   leaving `APNS_IMAGES_BACKEND_READY` false/unset. This prints a warning and
   does not bypass either profile or runtime image authorization. The default
   remains to require verified backend image support.
7. Confirm the archive embeds `HorizonNotificationService.appex`, signed under
   its own profile, with matching version/build numbers. Export options map the
   app and extension IDs separately; a global main-profile override is invalid.

Disabled builds use no APS entitlement. Enabled Debug builds request
`development` (Apple sandbox); Release builds request `production`.
TestFlight uses production APNs. Simulator results are not real delivery proof.
The current server provider key is production-only. No silent-push/background-fetch
mode was added. The NSE itself does not request the APS entitlement.

For local unsigned compilation, export `ENABLE_NATIVE_PUSH=true` before running
the existing local iOS check. A successful unsigned build does not verify signing
rights, APNs registration, or delivery.

The owner's **always push** instruction permits app/TestFlight fixes and retries
on standard public runners without another prompt per attempt. Ask separately
before paid/private/larger-runner jobs, Apple capability/resource changes,
credential permissions, backend deployment, and real pushes. Prefer the local Mac
preflight and one approved TestFlight run rather than duplicate cloud jobs.
Deployment does not run simulator/UI tests; the owner tests the phone UI.

## 5. Enable and accept on a real phone

For the newly deployed image service, use the existing TestFlight build 1018.
Open **Settings > Native notifications > Refresh notification support** (or pull
to refresh), confirm the protected image service is available, enable/register
native notifications and grant iOS permission, then explicitly enable
**Include camera images on the lock screen**. A trusted HTTPS NVR session and
phone connectivity are required. No restart/rebuild is necessary.

1. Install the approved push-enabled build and sign into the intended NVR.
2. Open **Settings > Native notifications**. Check build support, server
   provider, and iOS permission. Permission is requested by an explicit enable
   action, not silently on startup.
3. Choose all currently allowed cameras or an explicit selection. An empty
   selection means no camera alerts; a manual test can still reach the device.
4. Enable and wait for successful server registration. Verify token-free device
   metadata. Ask the owner before sending any real push, including a test.
   Apple acceptance means APNs accepted the request, not guaranteed display.
5. Test foreground/background/terminated delivery, Focus and notification
   settings, cellular/Wi-Fi, and taps into review/event/camera destinations.
6. Confirm current camera rules, suspension, cooldowns, role changes, and
   selected-camera filtering. Delivery rechecks database permissions rather
   than trusting a role cached when an alert was queued.
7. Test disable/re-enable, logout, token renewal, account/server changes, and a
   failed unregister. Ensure a fresh Apple registration follows re-enabling.
8. Open a config/password/bookmark/export editor and confirm notification
   navigation is deferred until the editor closes.
9. Separately opt into Lock Screen image previews for this account/device.
   Coordinate an authorized event/review/camera reference with the backend
   owner; a no-reference test will not exercise the image path. Confirm visible
   receipt separately from APNs acceptance.
10. Verify image opt-out, account/server changes, role/camera revocation,
    unregister/logout, offline/auth failure, and extension deadline fallback.

Destinations accept known route kinds and identifiers, never arbitrary URLs.
They must match the current server and load data using current authenticated
APIs and camera access. Stale or deleted media must show an explicit error.

## Device alert controls and health protocol

New servers advertise `device_preferences`, `action_notifications`,
`health_notifications` and `supports_device_features` only when deployed.
Clients send optional registration `features: ["actions-v1", "health-v1"]` only
after negotiation; old registration bodies/defaults remain unchanged.

- GET/POST `/api/notifications/apns/devices/{installation_id}/preferences`
  uses a revisioned full wrapper: `revision`, `camera_snooze_until`,
  nullable `quiet_hours` and default-off `health_alerts`. Conflicts return 409.
  Quiet hours use IANA time zones, minute-of-day bounds and ISO weekdays;
  overnight windows belong to the starting weekday.
- POST `/api/notifications/apns/devices/{installation_id}/snooze`
  accepts the current camera and 900/3600 seconds, or 0 to resume.
  Only the current account's installation is changed, never global rules.
- Activity category `HORIZON_ACTIVITY` supports foreground/unlocked Live,
  Review and camera-snooze actions. Stateful actions are bound to the locally
  registered account; current authentication and camera access are rechecked.
- GET `/api/notifications/apns/resolve/{kind}/{identifier}` verifies current
  database/session/camera authorization independently of thumbnail existence
  before new notification actions open existing media endpoints.
- GET `/api/notifications/apns/health` returns `sampled_at`, `checks_complete`
  and scoped `issues`. Unknown/stale required checks are incomplete, not healthy.
  Health kind/category is sent only to a negotiated, explicitly opted-in
  installation, uses generic text and never requests an image attachment.

These client contracts are compiled/signed/uploaded in build 1020 with 219 core
tests and 30 CI guards passing. The matching new backend feature rollout remains
unreleased, blocked on approved relay connectivity and supported Linux
HTTP/synthetic-media acceptance. The earlier image service is ready; this does
not attest new device-preference/health/control/protection readiness.
No feature or subscription is enabled by documentation.

## Image privacy and fallback

Images default off and require an explicit Lock Screen privacy warning. Only an
opted-in account's scoped session snapshot is saved in the dedicated device-only
Keychain group, accessible after first unlock. Logout/account changes revoke it
before forgetting/activating a session, including the explicit server-cleanup
bypass. Revocation failure is surfaced rather than claiming successful logout.
Delivered notifications are cleared on image opt-out/account changes, but
already accepted/copied notifications cannot be guaranteed recalled.

The NSE uses authenticated HTTPS to the saved NVR, rejects every redirect,
rechecks session generation, and falls back to original text on failure or its
15-second budget. Downloads are bounded to 2 MiB and 2,000,000 source pixels,
then downsampled to at most 1024 pixels per dimension and re-encoded as JPEG.
Successful attachment files remain available for Apple's handoff; failed files
are removed, and old extension-owned cache directories are cleaned later.

## Cleanup and troubleshooting

Normal logout stops local notifications and unregisters on the server before
forgetting the session. If cleanup fails, logout is blocked with an error.
The explicit **Disconnect without server push cleanup** action allows leaving
anyway, but retains cleanup debt. Sign back into the original account/server
to finish it before enabling push for a different account/server. Apple may
already have accepted notifications; unregistering cannot recall those.

- **Build support not enabled:** use an intentionally enabled, correctly signed build.
- **Provider unavailable / 404:** deploy the validated companion backend first.
- **Topic mismatch:** server topic, app bundle ID, App ID, and profile must agree.
- **Apple registration timeout/failure:** inspect entitlement, connectivity, and
  permission. No device token is displayed or saved in app preferences.
- **Apple rejection:** check production versus sandbox, token/topic, key scope,
  team/key IDs, server clock, and mounted P-256 key. Do not log secrets or tokens.
- **Accepted, no banner:** inspect phone notification settings/Focus/connectivity.
  APNs is best-effort; do not report acceptance as confirmed delivery.
- **No camera alerts:** verify notification rules, suspension/cooldown, selected
  cameras, permissions, and the restarted provider worker.

APNs 410 cleanup is guarded by token/environment/installation and invalidation
time so delayed rejection cannot delete a newer registration. Browser
subscriptions remain independent of native registrations.
