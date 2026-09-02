import LocalBridgeBackend
import SwiftUI
import WebKit

/// The login window: Google's own sign-in, hosted.
///
/// **Spike 2 of the architecture design**, and the first version of the thing
/// that eventually replaces pasting a header by hand. Two questions it exists
/// to answer, both recorded in the session 5 journal §5: whether Google's
/// sign-in works inside an embedded `WKWebView` at all, and whether
/// `WKHTTPCookieStore` hands over everything including `HttpOnly` cookies.
///
/// The data store is **non-persistent**, so signing in here leaves nothing
/// behind in a shared cache and signing out is deleting an object.
@MainActor
struct CookieCaptureView: View {
    /// Why the person is looking at this. `nil` on a first run, where there is
    /// nothing to explain.
    let reason: String?

    /// Called once a capture has reached the Keychain. The window does not
    /// dismiss itself - the environment re-runs its launch and the phase
    /// changes underneath it, which keeps "what is on screen" a function of
    /// one value rather than of two views agreeing.
    let onSaved: () async -> Void

    @State private var model: CookieCaptureModel

    /// `autoSaveAllowed` defaults to `false` - the safe behaviour, not the
    /// convenient one - so guard 2 is structural: a call site that forgets to
    /// opt in gets the manual button, never a silent auto-save, and it is
    /// `GChatMacApp` alone that passes `true`, because `.needsSignIn` is the
    /// one place there is nothing yet in the Keychain to overwrite. See
    /// `CookieCaptureModel.autoSaveAllowed`.
    init(reason: String?, autoSaveAllowed: Bool = false, onSaved: @escaping () async -> Void) {
        self.reason = reason
        self.onSaved = onSaved
        _model = State(
            initialValue: CookieCaptureModel(autoSaveAllowed: autoSaveAllowed, onSaved: onSaved)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            WebView(model: model)
            Divider()
            controls
        }
        .frame(minWidth: 900, minHeight: 700)
        .task { await model.refreshStoredSession() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let reason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(model.status).font(.callout)
                Text(model.pageURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The nine-day fuse on COMPASS is what decides how often
                // somebody signs in again, so it belongs on screen rather than
                // in a log.
                if let stored = model.storedSession {
                    Text("Keychain: \(stored)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Hidden while auto-save is still working towards a session -
            // see `CookieCaptureModel.showsManualControls`. They reappear the
            // moment that path can no longer finish on its own, so a failed
            // automatic capture is never a dead end.
            if model.showsManualControls {
                Button("Capture now") { model.capture() }
                Button("Save and continue") {
                    Task {
                        if await model.save() {
                            await onSaved()
                        }
                    }
                }
                .disabled(!model.canSave)
            }
        }
        .padding(12)
    }
}

private struct WebView: NSViewRepresentable {
    let model: CookieCaptureModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent: nothing survives this window, which is what makes
        // "discard the web view" a real logout rather than a gesture.
        configuration.websiteDataStore = .nonPersistent()

        // Google's sign-in opens parts of the flow in a new window. A
        // WKWebView with no uiDelegate silently drops those, which presents as
        // a button that does nothing at all - no error, no navigation.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Chat gates on this. Without an accepted User-Agent it authenticates
        // the session and then serves its unsupported-browser page.
        webView.customUserAgent = LocalBridgeBackend.captureUserAgent
        webView.navigationDelegate = context.coordinator
        model.attach(webView)
        LoginTrace.note("UA: \(LocalBridgeBackend.captureUserAgent.prefix(60))…")
        webView.load(URLRequest(url: URL(string: "https://chat.google.com/")!))
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: CookieCaptureModel

        init(model: CookieCaptureModel) {
            self.model = model
        }

        // MARK: Navigation

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                let target = navigationAction.targetFrame == nil ? " [new window]" : ""
                LoginTrace.note("policy: allow\(target)", url: navigationAction.request.url)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            MainActor.assumeIsolated { LoginTrace.note("start", url: webView.url) }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            MainActor.assumeIsolated {
                LoginTrace.note("finish", url: webView.url)
                model.pageSettled(webView)
            }
        }

        // MARK: UI

        /// The likeliest fix for a sign-in button that does nothing.
        ///
        /// With no `uiDelegate`, `window.open` is a silent no-op - no error, no
        /// navigation, nothing in any log. Loading the request in the same view
        /// keeps the flow in one window, which is what a person expects from a
        /// sign-in sheet anyway.
        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            MainActor.assumeIsolated {
                LoginTrace.note(
                    "popup requested, loading in place",
                    url: navigationAction.request.url
                )
            }
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(
            _: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame _: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            MainActor.assumeIsolated { LoginTrace.note("js alert: \(message.prefix(120))") }
            completionHandler()
        }

        func webView(
            _: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame _: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            MainActor.assumeIsolated { LoginTrace.note("js confirm: \(message.prefix(120))") }
            completionHandler(true)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
            MainActor.assumeIsolated {
                LoginTrace.note("FAILED \(error.localizedDescription)", url: webView.url)
                model.failed(webView, error)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: any Error
        ) {
            MainActor.assumeIsolated {
                LoginTrace.note("FAILED (provisional) \(error.localizedDescription)", url: webView.url)
                model.failed(webView, error)
            }
        }
    }
}
