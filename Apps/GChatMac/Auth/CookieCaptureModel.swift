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

    /// Whether this window may complete sign-in with no button press.
    ///
    /// A property of *this window*, passed in rather than inferred, because
    /// the reason `save()` was ever an explicit action - "overwriting a
    /// working session with a worse capture is a real way to lose one" -
    /// only stops applying when there is nothing yet to overwrite.
    /// Defaults to `false` - the safe behaviour - so a call site that forgets
    /// to pass it gets the manual button rather than a silent auto-save.
    /// `CookieCaptureView` is presented only from `.needsSignIn` today, where
    /// it is explicitly passed `true`, but a future call site that reopens
    /// this view over a session already in the Keychain inherits safety by
    /// doing nothing, rather than this file guessing why it was opened.
    private let autoSaveAllowed: Bool

    /// Called once a save - automatic or by the button - has reached the
    /// Keychain.
    private let onSaved: () async -> Void

    /// Latches the moment a capture looks complete enough to auto-save, and
    /// never resets.
    ///
    /// `pageSettled` fires on every navigation that settles on Chat's own
    /// origin, and Google's post-login redirect chain settles more than
    /// once. Without this, a later, unluckier navigation - a rotated cookie,
    /// a redirect that briefly holds a smaller cookie set - could silently
    /// replace a good session with a worse one. It only latches once a
    /// capture actually looked save-worthy, so a settle that arrives before
    /// Chat has issued its own cookies does not spend the one attempt on
    /// nothing.
    private var hasAutoSaved = false

    init(autoSaveAllowed: Bool = false, onSaved: @escaping () async -> Void = {}) {
        self.autoSaveAllowed = autoSaveAllowed
        self.onSaved = onSaved
    }

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
        attemptAutoSave(capture)
    }

    /// Saves without a button press, the first time a capture looks
    /// complete. See `autoSaveAllowed` and `hasAutoSaved` for the two guards
    /// this rests on.
    ///
    /// Deliberately does not call `save()`: that path sets "Saved to the
    /// Keychain." and then awaits `refreshStoredSession()` before returning,
    /// which is a real round trip a person reading the manual button's
    /// result should see - and exactly the round trip that would flash a
    /// success message nobody has time to read here, since `onSaved()` is
    /// about to replace this whole window. This writes the credential and,
    /// on success, goes straight to `onSaved()` with no message in between.
    private func attemptAutoSave(_ capture: CookieCapture) {
        guard autoSaveAllowed, capture.session != nil, !hasAutoSaved else { return }
        hasAutoSaved = true
        // Overwrites `capture.report.verdict`, which is a diagnostic line -
        // "PASS", "TOO EARLY" - meant for a person deciding whether to click
        // the button, not for someone watching sign-in complete on its own.
        status = "Signing in…"
        Task {
            guard await writeToKeychain(capture) else { return }
            await onSaved()
        }
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
        let saved = await writeToKeychain(capture)
        if saved {
            status = "Saved to the Keychain."
        }
        await refreshStoredSession()
        return saved
    }

    /// The actual Keychain write, shared by `save()` and `attemptAutoSave(_:)`.
    /// Sets `status` on every outcome except a clean success, which the two
    /// callers disagree about showing at all.
    private func writeToKeychain(_ capture: CookieCapture) async -> Bool {
        do {
            let saved = try await capture.save(to: credentials)
            if !saved {
                status = "Nothing to save: no cookie in this capture belongs to Chat."
            }
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
