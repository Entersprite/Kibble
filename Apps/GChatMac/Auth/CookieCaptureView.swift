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
    @State private var model = CookieCaptureModel()

    var body: some View {
        VStack(spacing: 0) {
            WebView(model: model)
            Divider()
            controls
        }
        .frame(minWidth: 900, minHeight: 700)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.callout)
                Text(model.pageURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Capture now") { model.capture() }
            Button("Save for --backend=local") { model.saveHeader() }
                .disabled(!model.canSave)
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
