import Foundation
import LocalBridgeBackend
import Observation

/// Watches the login web view, drains its cookie store, and puts the result in
/// the Keychain.
///
/// ## The seams, and what each one is for
///
/// This header used to say the file could not be unit-tested - "it needs a web
/// view, a Google account and a Keychain" - and that was true of the version
/// that named `WKWebView` and `KeychainCredentialStore` directly. Two seams
/// changed it, and `CookieCaptureModelTests` is what they bought:
///
/// - `LoginWebView` is the three things this needs from a web view
///   (`currentURL`, `currentTitle`, `allCookies()`), handing back Foundation's
///   `HTTPCookie` rather than a WebKit type. That is what keeps the
///   `HTTPCookie` to `CapturedCookie` mapping in this package, where a test
///   can reach it.
/// - `CaptureCustody` is storage, and it exists because **the Keychain cannot
///   be faked from here**: `SecretStorage` and `KeychainCredentialStore`'s
///   injectable initialiser are both internal to `LocalBridgeBackend`, so a
///   model that named the store directly could only ever be driven against
///   the real Keychain - which would mean a test suite that overwrote the
///   person's live session (ruling R7).
///
/// The untestable residue is now one `WKWebView` conformance in the app
/// target, which is the shape CLAUDE.md asks for: a boundary that cannot be
/// unit-tested should be one file wide.
///
/// ## What still belongs below the seam
///
/// Every decision about *content* - which cookies may be replayed to Chat
/// (`CookieScope`), what the report says (`CookieCaptureReport`), how the
/// credential is encoded and stored - lives in `LocalBridgeBackend` and has
/// its own tests there. What this file decides is sequencing and disclosure:
/// when to capture, when a capture may save itself, when sign-in is complete,
/// and what may be shown on screen or written to a file.
@MainActor
@Observable
public final class CookieCaptureModel {
    public private(set) var status = "Loading Google sign-in…"

    /// What the web view is pointed at, **host and path only**.
    ///
    /// Redacted through `LoginTrace.redact(_:)` rather than kept as an
    /// `absoluteString`, and reusing that function rather than restating the
    /// rule: Google's sign-in URLs carry identifiers and one-time tokens in
    /// their query strings, `LoginTrace`'s own header says so, and this string
    /// reaches two sinks that must not carry them - `CookieCaptureView` draws
    /// it, and `record(_:url:title:)` hands the same value to
    /// `CookieCapture(pageURL:)`, from which `cookie-capture-report.txt`
    /// writes it out under `page:`. That report's own doc comment promises
    /// "nothing here needs redacting before it is pasted into an issue"; this
    /// is what keeps that sentence true. One rule, in one place, for the same
    /// reason `accepts(host:for:)` below defers to one host rule.
    public private(set) var pageURL = ""

    public private(set) var canSave = false

    /// What is already in the Keychain, for the window to show. Refreshed after
    /// a save so the person sees the thing they just created.
    public private(set) var storedSession: String?

    private weak var webView: (any LoginWebView)?
    private var lastCapture: CookieCapture?

    /// What the login web view is pointed at, and what host it claims to be.
    ///
    /// `pageSettled`'s host gate reads `configuration.host` through
    /// `accepts(host:for:)` rather than a literal, so the navigation target
    /// and the accepted origin cannot separately drift the way
    /// `LoginWebViewConfiguration`'s own doc comment says the two hard-coded
    /// copies once did.
    private let configuration: LoginWebViewConfiguration

    /// Where the captured session is stored. Never the Keychain directly -
    /// see `CaptureCustody`'s own doc comment (ruling R7).
    private let custody: any CaptureCustody

    /// Where the safe-to-share report is written. `nil` when the directory
    /// could not be resolved, in which case the report is silently skipped
    /// rather than the login window crashing over a diagnostic file.
    private let reportDirectory: URL?

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

    /// Called once a save - automatic or by the button - has reached
    /// storage.
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

    /// Latches the one `onSaved()` this window will ever send.
    ///
    /// A **second** latch rather than a reuse of `hasAutoSaved`, whose meaning
    /// is deliberately narrower: that one marks the single *automatic attempt*
    /// having been spent, and `showsManualControls` depends on it flipping the
    /// instant `attemptAutoSave` starts - before the Keychain write it started
    /// has returned. That gap is the bug: "Save and continue" is clickable
    /// while the automatic save is still in flight, and both routes finish by
    /// completing sign-in. Two `onSaved()` calls meant two
    /// `AppEnvironment.signedIn()` calls, which built two engines and two
    /// models over one store with the first leaked and never stopped.
    ///
    /// `AppEnvironment.signedIn()` is now idempotent too. Both guards are
    /// wanted: this one stops the duplicate at its source, and that one holds
    /// for any future caller that reaches it another way.
    private var hasCompleted = false

    /// Whether `CookieCaptureView` should show its manual "Capture now" /
    /// "Save and continue" buttons.
    ///
    /// Auto-save exists precisely so those buttons need no press; while it is
    /// still working towards one, they are confusing furniture. But they are
    /// also the only fallback for the one thing auto-save cannot recover
    /// from itself - a capture that never turns into a session, reported on
    /// `status` as "Could not save: ..." or "Nothing to save: ...". No
    /// second flag is needed to notice that: `hasAutoSaved` already marks the
    /// moment the one automatic attempt this window will ever make has been
    /// spent (see its own doc comment), which is exactly when either outcome
    /// is now knowable. If it is about to succeed, `onSaved()` is already
    /// replacing this whole window, so the buttons reappearing for a moment
    /// costs nothing; if it did not, they are the way forward that keeps
    /// this from being a dead end.
    public var showsManualControls: Bool {
        !autoSaveAllowed || hasAutoSaved
    }

    public init(
        autoSaveAllowed: Bool = false,
        configuration: LoginWebViewConfiguration = .chat,
        custody: any CaptureCustody = KeychainCaptureCustody(),
        reportDirectory: URL? = try? SystemLaunchServices.supportDirectory(),
        onSaved: @escaping () async -> Void = {}
    ) {
        self.autoSaveAllowed = autoSaveAllowed
        self.configuration = configuration
        self.custody = custody
        self.reportDirectory = reportDirectory
        self.onSaved = onSaved
    }

    public func attach(_ webView: any LoginWebView) {
        self.webView = webView
    }

    /// Whether a settled page is Chat's own origin.
    ///
    /// The label boundary is load-bearing rather than pedantic, and this is
    /// the second time the project has needed to say so: `CookieScope
    /// .domainMatches` carries the same rule for the cookies themselves, and
    /// this file used `contains`, which admits `chat.google.com.evil.example`.
    /// Kept deliberately identical in shape to that one, lowercasing both
    /// sides the same way it does - a second rule for the same question is
    /// how the two drift. Not copied: `domainMatches` also strips a leading
    /// dot, which is legacy spelling for a *cookie's* `domain` attribute
    /// (RFC 6265) and cannot appear in a URL's `host()`, which this compares
    /// instead.
    static func accepts(host: String, for configuration: LoginWebViewConfiguration) -> Bool {
        guard let candidate = configuration.host?.lowercased() else { return false }
        let host = host.lowercased()
        return host == candidate || host.hasSuffix("." + candidate)
    }

    /// Called when a navigation finishes.
    ///
    /// It captures **only once Chat's own origin has loaded**, which is the
    /// whole re-scope of this spike: `COMPASS` and `OSID` are issued by Chat,
    /// not by the accounts host, so a capture taken when sign-in completes
    /// looks complete and is missing exactly the two cookies that matter.
    public func pageSettled(_ webView: any LoginWebView) {
        // Redacted **before** the host guard, not after it: every intermediate
        // `accounts.google.com` navigation settles here too, and those are
        // exactly the URLs whose query strings carry the one-time tokens.
        pageURL = LoginTrace.redact(webView.currentURL)
        guard let host = webView.currentURL?.host(), Self.accepts(host: host, for: configuration) else {
            status = "Signing in… (waiting for Chat itself to load)"
            return
        }
        status = "Chat loaded. Capturing…"
        capture()
    }

    public func failed(_ webView: any LoginWebView, _ error: any Error) {
        pageURL = LoginTrace.redact(webView.currentURL)
        // Worth surfacing rather than swallowing: if Google refuses an embedded
        // web view, this is where it shows up.
        status = "Navigation failed: \(error.localizedDescription)"
    }

    /// Note the missing host gate: "Capture now" may be pressed on any page,
    /// and it becomes visible in exactly the "auto-save did not finish, try
    /// manually" state where someone is plausibly still mid-flow on
    /// `accounts.google.com`. That is deliberate - a manual escape hatch that
    /// refused to fire would be no escape - which is why the URL is redacted
    /// here rather than trusted to be Chat's own.
    public func capture() {
        guard let webView else { return }
        let title = webView.currentTitle ?? ""
        let url = LoginTrace.redact(webView.currentURL)
        Task { @MainActor in
            let cookies = await webView.allCookies()
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
            await completeSignIn()
        }
    }

    /// The one and only exit from this window, at most once. See
    /// `hasCompleted`.
    private func completeSignIn() async {
        guard !hasCompleted else { return }
        hasCompleted = true
        await onSaved()
    }

    /// Puts the captured session in storage, and says whether it landed.
    ///
    /// Returns `false` for both "nothing in this capture belongs to Chat" and
    /// "storage refused" - the caller's only decision is whether to continue
    /// into the app, and neither of those is a session it could continue
    /// with. `status` carries which one it was, on screen, in words.
    ///
    /// The manual route, for the one thing `attemptAutoSave` cannot recover
    /// from itself - a capture that never became a session. It is no longer
    /// the *only* route: `autoSaveAllowed` windows save without a press, and
    /// this is what `showsManualControls` exists to offer once that attempt
    /// has been spent. The caution it was written for - overwriting a working
    /// session with a worse capture is a real way to lose one - is now carried
    /// by `autoSaveAllowed` defaulting to `false`, which is where it belongs,
    /// since it only ever applied when there was already something to
    /// overwrite.
    ///
    /// **Completes sign-in itself on success**, rather than leaving that to
    /// the button's own closure. That is what puts both routes behind one
    /// latch - see `hasCompleted` - so a press landing while the automatic
    /// save is still in flight cannot exit this window twice.
    @discardableResult
    public func save() async -> Bool {
        guard let capture = lastCapture else { return false }
        let saved = await writeToKeychain(capture)
        if saved {
            status = "Saved to the Keychain."
        }
        await refreshStoredSession()
        if saved {
            await completeSignIn()
        }
        return saved
    }

    /// The actual save, shared by `save()` and `attemptAutoSave(_:)`.
    /// Sets `status` on every outcome except a clean success, which the two
    /// callers disagree about showing at all.
    private func writeToKeychain(_ capture: CookieCapture) async -> Bool {
        do {
            let saved = try await custody.save(capture)
            if !saved {
                status = "Nothing to save: no cookie in this capture belongs to Chat."
            }
            return saved
        } catch {
            status = "Could not save: \(KeychainDiagnosis.explain(error))"
            return false
        }
    }

    public func refreshStoredSession() async {
        do {
            storedSession = try await custody.storedDescription()
        } catch {
            storedSession = KeychainDiagnosis.explain(error)
        }
    }

    /// Writes the report - never the credential - beside the app's database.
    private func write(_ contents: String, to name: String) {
        guard let reportDirectory else { return }
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try? contents.write(
            to: reportDirectory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }
}
