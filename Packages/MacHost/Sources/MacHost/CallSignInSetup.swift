import Foundation
import LocalBridgeBackend
import Observation

/// Optional call authentication before the new app session takes ownership of cookies.
/// Chat is already saved; only this login's fresh browser may supply call cookies.
@MainActor
@Observable
public final class CallSignInSetup {
    public private(set) var isActive = false
    public private(set) var isSaving = false
    public private(set) var isFinishing = false
    public private(set) var status = "Setting up calls…"

    private let custody: any CaptureCustody
    @ObservationIgnored private weak var webView: (any LoginWebView)?
    @ObservationIgnored private var onFinished: (() async -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var hasFinished = false
    @ObservationIgnored private var chatCapture: CookieCapture?

    init(custody: any CaptureCustody) {
        self.custody = custody
    }

    func begin(
        _ webView: any LoginWebView,
        belongingTo capture: CookieCapture,
        onFinished: @escaping () async -> Void
    ) {
        guard !isActive, !hasFinished else { return }
        self.webView = webView
        self.onFinished = onFinished
        chatCapture = capture
        isActive = true
        status = "Setting up calls. Use the same Google account if prompted, or continue to Chat."
        webView.navigate(to: LoginWebViewConfiguration.calls.startURL)
    }

    func pageSettled(_ webView: any LoginWebView) {
        guard isActive, !isSaving, !isFinishing, let chatCapture else { return }
        guard let host = webView.currentURL?.host(),
              CookieCaptureModel.accepts(host: host, for: .calls) else {
            status = "Finish signing in for calls with the same Google account, or continue to Chat."
            return
        }
        isSaving = true
        status = "Checking call sign-in…"
        revision += 1
        let scope = revision
        saveTask = Task {
            let cookies = await webView.allCookies()
            guard revision == scope, !Task.isCancelled else { return }
            do {
                let count = try await custody.saveCallCookies(
                    Self.captured(cookies),
                    belongingTo: chatCapture
                )
                guard revision == scope, !Task.isCancelled else { return }
                isSaving = false
                saveTask = nil
                if count > 0 {
                    await finish()
                } else {
                    status = "Call sign-in isn't ready. Finish signing in, then try again, "
                        + "or continue to Chat."
                }
            } catch {
                guard revision == scope, !Task.isCancelled else { return }
                isSaving = false
                saveTask = nil
                status = Self.failureMessage(error)
            }
        }
    }

    public func retry() {
        guard isActive, !isSaving, !isFinishing, let webView else { return }
        status = "Opening call sign-in…"
        webView.navigate(to: LoginWebViewConfiguration.calls.startURL)
    }

    func navigationFailed() {
        guard isActive, !isSaving, !isFinishing else { return }
        status = "Call sign-in couldn't load. Try again, or continue to Chat."
    }

    /// Cancellation is followed by a join: an account verifier may already be
    /// merging cookies, and the new session must not race that final write.
    public func continueToChat() async {
        guard isActive, !isFinishing else { return }
        isFinishing = true
        status = "Finishing Chat sign-in…"
        revision += 1
        let pending = saveTask
        pending?.cancel()
        await pending?.value
        saveTask = nil
        isSaving = false
        await finish()
    }

    private func finish() async {
        guard !hasFinished else { return }
        hasFinished = true
        isFinishing = true
        isActive = false
        webView = nil
        chatCapture = nil
        let completion = onFinished
        onFinished = nil
        await completion?()
    }

    private static func failureMessage(_ error: any Error) -> String {
        switch error as? MeetWebCaptureError {
        case .accountMismatch:
            "Calls use a different Google account. Use your Chat account, or continue to Chat."
        case .sessionChangedDuringVerification:
            "Chat sign-in changed. Call sign-in wasn't saved. You can continue to Chat."
        case .callSignInVerificationFailed:
            "Finish signing in for calls, then try again, or continue to Chat."
        default:
            "Call sign-in couldn't be verified. Try again, or continue to Chat."
        }
    }

    private static func captured(_ cookies: [HTTPCookie]) -> [CapturedCookie] {
        cookies.map {
            CapturedCookie(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly, expiresAt: $0.expiresDate
            )
        }
    }
}
