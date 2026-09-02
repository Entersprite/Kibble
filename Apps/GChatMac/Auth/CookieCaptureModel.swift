import Foundation
import LocalBridgeBackend
import Observation
import WebKit

/// Watches the login web view, drains its cookie store, and puts the result in
/// the Keychain.
///
/// Deliberately thin. Every decision worth testing - which cookies may be
/// replayed to Chat, what the report says, how the credential is encoded and
/// stored - lives in `LocalBridgeBackend`, because the app target is a shell
/// and because this file cannot be unit-tested: it needs a web view, a Google
/// account and a Keychain. What is left here is plumbing between three things
/// that each have their own tests.
@MainActor
@Observable
final class CookieCaptureModel {
    private(set) var status = "Loading Google sign-in…"
    private(set) var pageURL = ""
    private(set) var canSave = false

    /// What is already in the Keychain, for the window to show. Refreshed after
    /// a save so the person sees the thing they just created.
    private(set) var storedSession: String?

    private weak var webView: WKWebView?
    private var lastCapture: CookieCapture?
    private let credentials = KeychainCredentialStore()

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// Called when a navigation finishes.
    ///
    /// It captures **only once Chat's own origin has loaded**, which is the
    /// whole re-scope of this spike: `COMPASS` and `OSID` are issued by Chat,
    /// not by the accounts host, so a capture taken when sign-in completes
    /// looks complete and is missing exactly the two cookies that matter.
    func pageSettled(_ webView: WKWebView) {
        pageURL = webView.url?.absoluteString ?? ""
        guard let host = webView.url?.host(), host.contains("chat.google.com") else {
            status = "Signing in… (waiting for Chat itself to load)"
            return
        }
        status = "Chat loaded. Capturing…"
        capture()
    }

    func failed(_ webView: WKWebView, _ error: any Error) {
        pageURL = webView.url?.absoluteString ?? ""
        // Worth surfacing rather than swallowing: if Google refuses an embedded
        // web view, this is where it shows up.
        status = "Navigation failed: \(error.localizedDescription)"
    }

    func capture() {
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let title = webView.title ?? ""
        let url = webView.url?.absoluteString ?? ""
        Task { @MainActor in
            let cookies = await store.allCookies()
            self.record(cookies, url: url, title: title)
        }
    }

    /// Hands every cookie the store held to `CookieCapture`, unfiltered.
    ///
    /// Unfiltered on purpose. Deciding *here* which cookies matter is what
    /// produced the defect this replaces - a `domain.contains("google.com")`
    /// test that swept `accounts.google.com` credentials and
    /// `workspace.google.com` analytics into a header meant for Chat. The rule
    /// belongs somewhere it can be tested against the real inventory, and the
    /// excluded cookies stay in the report so the next such defect is visible.
    private func record(_ cookies: [HTTPCookie], url: String, title: String) {
        let capture = CookieCapture(
            cookies: cookies.map {
                CapturedCookie(
                    name: $0.name,
                    value: $0.value,
                    domain: $0.domain,
                    path: $0.path,
                    isSecure: $0.isSecure,
                    isHTTPOnly: $0.isHTTPOnly,
                    expiresAt: $0.expiresDate
                )
            },
            capturedAt: Date(),
            pageURL: url,
            pageTitle: title
        )
        lastCapture = capture
        canSave = capture.session != nil
        status = capture.report.verdict
        write(capture.report.text, to: "cookie-capture-report.txt")
    }

    /// Puts the captured session in the Keychain, and says whether it landed.
    ///
    /// Returns `false` for both "nothing in this capture belongs to Chat" and
    /// "the Keychain refused" - the caller's only decision is whether to
    /// continue into the app, and neither of those is a session it could
    /// continue with. `status` carries which one it was, on screen, in words.
    ///
    /// It is still an explicit action rather than an automatic one, because
    /// overwriting a working session with a worse capture is a real way to
    /// lose one.
    @discardableResult
    func save() async -> Bool {
        guard let capture = lastCapture else { return false }
        do {
            let saved = try await capture.save(to: credentials)
            status = saved
                ? "Saved to the Keychain."
                : "Nothing to save: no cookie in this capture belongs to Chat."
            await refreshStoredSession()
            return saved
        } catch {
            status = "Could not save: \(KeychainDiagnosis.explain(error))"
            return false
        }
    }

    func refreshStoredSession() async {
        do {
            storedSession = try await credentials.summary(at: Date())?.description
        } catch {
            storedSession = KeychainDiagnosis.explain(error)
        }
    }

    /// Writes the report - never the credential - beside the app's database.
    private func write(_ contents: String, to name: String) {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("GChat", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }
}
