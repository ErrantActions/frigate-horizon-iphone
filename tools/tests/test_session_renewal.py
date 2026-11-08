import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class TestSessionRenewal(unittest.TestCase):
    def test_auth_renewal_is_supported_cookie_get_with_coordinated_work(self):
        core = source("Sources/HorizonCore/SessionRenewalCoordinator.swift")
        for token in ['address.endpoint(["api","auth"])', "if let pending", "response.statusCode == 202",
                      '"remote-user"', '"remote-role"', "HTTPCookie.requestHeaderFields",
                      "completionHandler(nil)", "setCookie(cookie)", "try Task.checkCancellation()"]:
            self.assertIn(token, core)
        for token in ["password", "Bearer", "print(", "UserDefaults", "serverTrust"]:
            self.assertNotIn(token, core)

    def test_api_preflights_session_and_never_replays_a_write_after_401(self):
        api = source("App/Networking/HorizonAPI.swift")
        buffered = api.split("private func dataWithHTTPResponse(")[1]
        self.assertIn("try await verifySession()", buffered)
        self.assertIn('if (request.httpMethod ?? "GET") == "GET"', buffered)
        self.assertIn("try await verifySession(force: true)", buffered)
        self.assertIn("receipt.username != expected", api)
        self.assertIn("\nextension Notification.Name {", api)
        self.assertNotIn("                extension Notification.Name", api)

    def test_new_cookies_persist_without_registering_or_resetting_notification_choices(self):
        model = source("App/AppModel.swift")
        persist = model.split("func persistSession(from")[1].split("func reportPersistenceFailure")[0]
        for token in ["guard api === client", "SessionVault.saveProfile", "SessionVault.save(client)",
                      "refreshImageSession", "address == client.address"]:
            self.assertIn(token, persist)
        for token in ["push.attach", ".register", "camera_ids", "savedCameraIDs =", "password"]:
            self.assertNotIn(token, persist)
        self.assertIn("private var expiryVerification: Task", model)
        self.assertIn('Task.sleep(for: .seconds(30))', model)
        self.assertIn("UIApplication.shared.applicationState == .active", model)
        self.assertIn("RecordedViewingRegistry.hasPictureInPicture", model)
        self.assertIn(".horizonSessionCookiesChanged", source("App/HorizonApp.swift"))
        api = source("App/Networking/HorizonAPI.swift")
        self.assertIn("let changed = lastNotifiedSession != saved", api)
        self.assertIn("guard changed else { return }", api)

    def test_media_401_only_prompts_after_account_verification_and_403_is_not_expiry(self):
        view = source("App/Views/LiveView.swift")
        self.assertIn("reportedAuthFailure && model.connectionIssue?.httpStatus == 401", view)
        model = source("App/AppModel.swift")
        report = model.split("func reportSessionExpiry(")[1].split("func persistSession")[0]
        self.assertIn("client.verifySession(force: true", report)
        self.assertIn("guard expiryVerification == nil", report)
        issue = source("Sources/HorizonCore/ConnectionIssue.swift")
        self.assertIn("case 403: kind = .accessDenied", issue)

    def test_every_native_mp4_range_can_use_rotated_account_cookies(self):
        core = source("Sources/HorizonCore/RecordedMP4Reader.swift")
        self.assertIn("cookieProvider())", core)
        self.assertIn("cookieStore.replace(with:", core)
        self.assertIn("SavedSession.cookiesForRequest", core)
        client = source("App/Networking/HorizonRecordedHTTPClient.swift")
        self.assertIn("func mediaCookies()", client)
        self.assertIn("try await api.verifySession()", client)
