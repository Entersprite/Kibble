import Foundation
import LocalBridgeBackend
import Observation
import WebKit

/// Watches the login web view and drains its cookie store.
@MainActor
@Observable
final class CookieCaptureModel {
    private(set) var status = "Loading Google sign-in…"
    private(set) var pageURL = ""
    private(set) var canSave = false

    private weak var webView: WKWebView?
    private var lastReport: CookieCaptureReport?
    private var lastHeader: String?

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

    private func record(_ cookies: [HTTPCookie], url: String, title: String) {
        let relevant = cookies.filter { $0.domain.contains("google.com") }
        let now = Date()
        let report = CookieCaptureReport(
            capturedAt: now,
            pageURL: url,
            pageTitle: title,
            entries: relevant.map { cookie in
                CookieCaptureReport.Entry(
                    name: cookie.name,
                    domain: cookie.domain,
                    valueLength: cookie.value.count,
                    isHTTPOnly: cookie.isHTTPOnly,
                    isSecure: cookie.isSecure,
                    expiresInDays: cookie.expiresDate.map {
                        Int($0.timeIntervalSince(now) / 86400)
                    }
                )
            }
        )
        lastReport = report
        // Rebuilt in the store's own order and never shown: the report is what
        // is displayed, and it carries no values.
        lastHeader = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        canSave = report.hasChatScopedCookies

        status = report.verdict
        write(report.text, to: "cookie-capture-report.txt")
    }

    /// Writes the header where `--backend=local` looks for it.
    ///
    /// A separate, explicit action because it puts a credential in a file
    /// rather than the Keychain. That is the developer escape hatch, not the
    /// product; `CredentialStore` is what replaces it.
    func saveHeader() {
        guard let lastHeader else { return }
        write(lastHeader, to: "cookie-header.txt")
        status = "Saved. Relaunch with --backend=local to use it."
    }

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
