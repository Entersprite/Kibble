import AppKit
import Foundation
import SwiftUI
import WebKit

/// The browser every sign-in window shows: the first-run window, Add Account
/// and call sign-in recovery.
///
/// What the three must agree on is decided here, once:
///
/// - a **non-persistent** website data store, so nothing survives the window
///   and discarding it is a real sign-out rather than a gesture;
/// - the capture user agent, `LoginWebViewConfiguration`'s documented
///   exception: without an accepted one Chat authenticates the session and
///   then serves its unsupported-browser page;
/// - popups loaded in place: a web view with no UI delegate drops
///   `window.open` silently, which presents as a sign-in button that does
///   nothing at all;
/// - a load that fails reported to the window's model, so the window says so
///   instead of staying blank;
/// - the page's JavaScript dialogs as sheets on the window, answered only by
///   the person (`LoginPageDialog`), except in the first-run window, which
///   answers them itself as it always has (`LoginDialogPolicy`);
/// - back and forward swipes; and
/// - the page's host, for the window's subtitle, so the person can see whose
///   page is asking for their password.
///
/// What differs is passed in: which model the browser feeds, whether it
/// opens a page itself or waits for the model to seed cookies first, and
/// whether it writes `LoginTrace`.
struct LoginBrowser: NSViewRepresentable {
    /// What the browser tells the window's model.
    struct Events {
        /// Once, before the first page loads.
        var attached: @MainActor (WebKitLoginWebView) -> Void
        /// Each time a navigation finishes.
        var settled: @MainActor (any LoginWebView) -> Void
        /// A load that failed, never one superseded by the next
        /// (`LoginBrowser.reportsFailure`).
        var failed: @MainActor (any LoginWebView, any Error) -> Void
    }

    let start: URL?
    let traces: Bool
    /// How the page's JavaScript dialogs are answered.
    var dialogs = LoginDialogPolicy.ask
    let events: Events
    let pageHost: @MainActor (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let view = Self.makeWebView()
        context.coordinator.attach(view)
        if let start {
            view.load(URLRequest(url: start))
        }
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> LoginBrowserDelegate {
        LoginBrowserDelegate(events: events, traces: traces, dialogs: dialogs, pageHost: pageHost)
    }

    static func dismantleNSView(_: WKWebView, coordinator: LoginBrowserDelegate) {
        coordinator.endDialogs()
    }

    /// The web view every sign-in window uses, before any delegate is set.
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = LoginWebViewConfiguration.chat.userAgent
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    /// The host a window shows as its subtitle, or nothing for a page with
    /// none, such as the blank page before the first load.
    static func host(of url: URL?) -> String {
        url?.host()?.lowercased() ?? ""
    }

    /// Whether a failed load is one the window should report.
    ///
    /// Two failures are not failures. A navigation canceled because another
    /// replaced it is routine in Google's sign-in, which redirects through
    /// several pages; and a load interrupted by a policy change is a page
    /// handed to another app. Reporting either would put "Navigation
    /// failed" under a sign-in that is going fine.
    static func reportsFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return false
        }
        // WebKitErrorFrameLoadInterruptedByPolicyChange, from WebKit's legacy
        // error domain, which has no public Swift constant.
        return !(error.domain == "WebKitErrorDomain" && error.code == 102)
    }
}

/// How a sign-in browser answers the page's JavaScript dialogs.
enum LoginDialogPolicy {
    /// As sheets on the window, answered by the person.
    case ask
    /// At once, as the first-run window always has: an alert is dismissed
    /// and a confirmation accepted, so nothing in Google's flow waits on a
    /// dialog; a prompt gets no text. Each is written to `LoginTrace`.
    case answer
}

extension LoginBrowser {
    /// The capture model's browser: the first-run window and Add Account.
    /// It opens Chat itself.
    init(
        capturing model: CookieCaptureModel,
        traces: Bool = false,
        dialogs: LoginDialogPolicy = .ask,
        pageHost: @escaping @MainActor (String) -> Void
    ) {
        self.init(
            start: LoginWebViewConfiguration.chat.startURL,
            traces: traces,
            dialogs: dialogs,
            events: Events(
                attached: { model.attach($0) },
                settled: { model.pageSettled($0) },
                failed: { model.failed($0, $1) }
            ),
            pageHost: pageHost
        )
    }

    /// Call sign-in recovery's browser. It opens nothing: the model seeds
    /// the saved call cookies first, then navigates.
    init(recovering model: CallSignInRecovery, pageHost: @escaping @MainActor (String) -> Void) {
        self.init(
            start: nil,
            traces: false,
            events: Events(
                attached: { page in model.attach(page) { await page.seed($0) } },
                settled: { model.pageSettled($0) },
                failed: { _, _ in model.navigationFailed() }
            ),
            pageHost: pageHost
        )
    }
}

/// The browser's navigation and UI delegate, and the owner of the adapter the
/// model holds weakly.
@MainActor
final class LoginBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let events: LoginBrowser.Events
    private let traces: Bool
    private let policy: LoginDialogPolicy
    private let pageHost: @MainActor (String) -> Void
    private(set) var page: WebKitLoginWebView?
    private var shownHost: String?
    private var dialogs: [(alert: NSAlert, reply: LoginDialogReply)] = []
    private var closeObserver: (any NSObjectProtocol)?

    init(
        events: LoginBrowser.Events, traces: Bool, dialogs: LoginDialogPolicy = .ask,
        pageHost: @escaping @MainActor (String) -> Void
    ) {
        self.events = events
        self.traces = traces
        policy = dialogs
        self.pageHost = pageHost
    }

    /// Takes over a new web view's delegates and hands the model its page.
    func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        let page = WebKitLoginWebView(view)
        self.page = page
        events.attached(page)
        if traces {
            LoginTrace.note("UA: \(LoginWebViewConfiguration.chat.userAgent.prefix(60))…")
        }
    }

    // MARK: Navigation

    /// Every navigation is allowed, as WebKit's default does; the first-run
    /// window writes each decision to `LoginTrace`, as it always has.
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if traces {
            let target = navigationAction.targetFrame == nil ? " [new window]" : ""
            LoginTrace.note("policy: allow\(target)", url: navigationAction.request.url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        if traces {
            LoginTrace.note("start", url: webView.url)
        }
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        showHost(of: webView)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if traces {
            LoginTrace.note("finish", url: webView.url)
        }
        showHost(of: webView)
        if let page {
            events.settled(page)
        }
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        if traces {
            LoginTrace.note("FAILED \(error.localizedDescription)", url: webView.url)
        }
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error
    ) {
        if traces {
            LoginTrace.note("FAILED (provisional) \(error.localizedDescription)", url: webView.url)
        }
        fail(webView, error)
    }

    private func fail(_ webView: WKWebView, _ error: any Error) {
        showHost(of: webView)
        guard let page, LoginBrowser.reportsFailure(error) else { return }
        events.failed(page, error)
    }

    private func showHost(of webView: WKWebView) {
        let host = LoginBrowser.host(of: webView.url)
        guard host != shownHost else { return }
        shownHost = host
        pageHost(host)
    }

    // MARK: UI

    /// Google's sign-in opens parts of its flow in a new window. Loading the
    /// request in the same view keeps the flow in one window, which is what
    /// a person expects from a sign-in window anyway.
    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if traces {
            LoginTrace.note("popup requested, loading in place", url: navigationAction.request.url)
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        if traces {
            LoginTrace.note("js alert: \(message.prefix(120))")
        }
        handle(.alert(message), in: webView, host: frame.securityOrigin.host) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        if traces {
            LoginTrace.note("js confirm: \(message.prefix(120))")
        }
        handle(.confirm(message), in: webView, host: frame.securityOrigin.host) {
            completionHandler($0.confirmed)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        if traces {
            LoginTrace.note("js prompt: \(prompt.prefix(120))")
        }
        handle(.prompt(prompt, defaultText: defaultText), in: webView, host: frame.securityOrigin.host) {
            completionHandler($0.text)
        }
    }

    /// A page's dialog, answered as this window's policy says: at once in the
    /// first-run window, otherwise by the person. `host` names the page that
    /// asked, for the sheet's title.
    func handle(
        _ dialog: LoginPageDialog, in webView: WKWebView, host: String?,
        send: @escaping @MainActor (LoginPageDialog.Answer) -> Void
    ) {
        switch policy {
        case .answer: send(dialog.automaticAnswer)
        case .ask: present(dialog, in: webView, host: host, send: send)
        }
    }

    /// Shows a page's dialog as a sheet on the browser's window. With no
    /// window to show it on, the page is refused, as a closed one would be.
    private func present(
        _ dialog: LoginPageDialog, in webView: WKWebView, host: String?,
        send: @escaping @MainActor (LoginPageDialog.Answer) -> Void
    ) {
        let reply = LoginDialogReply(dialog: dialog, send: send)
        guard let window = webView.window else {
            reply.refuse()
            return
        }
        let alert = NSAlert()
        alert.messageText = LoginPageDialog.title(host: host)
        alert.informativeText = dialog.message
        alert.addButton(withTitle: "OK")
        if dialog.canCancel {
            alert.addButton(withTitle: "Cancel")
        }
        let field: NSTextField? = if case let .prompt(_, defaultText) = dialog {
            NSTextField(string: defaultText ?? "")
        } else {
            nil
        }
        if let field {
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        dialogs.append((alert, reply))
        watchForClose(window)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                reply.answer(response, text: field?.stringValue)
                self?.dialogs.removeAll { $0.reply === reply }
            }
        }
    }

    /// A window closing over an open dialog refuses it, so the page's
    /// question is never left unanswered.
    private func watchForClose(_ window: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDialogs() }
        }
    }

    /// Ends every open dialog with a refusal: on the window's closing, and
    /// when the browser leaves its window.
    func endDialogs() {
        let open = dialogs
        dialogs = []
        for dialog in open {
            dialog.alert.window.sheetParent?.endSheet(dialog.alert.window, returnCode: .cancel)
            dialog.reply.refuse()
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
    }
}
