#if DEBUG
    import AppKit
    import Foundation
    import MacHost
    import SwiftUI
    import WebKit

    /// A local media test. It neither creates a meeting nor rings anyone: the
    /// person supplies a Meet link and decides whether to join inside Meet.
    @MainActor
    struct MeetWebKitProbeView: View {
        @State private var cookies: [MeetWebProbeCookie]?
        @State private var link = ""
        @State private var destination: URL?
        @State private var status = "Loading the stored session…"

        var body: some View {
            VStack(spacing: 0) {
                if let cookies {
                    MeetProbeWebView(cookies: cookies, destination: destination) { status = $0 }
                } else {
                    ProgressView("Preparing Meet…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    TextField("Meet link or meeting code", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openLink)
                    Button("Open Meet") { destination = URL(string: "https://meet.google.com/") }
                    Button("Open Link", action: openLink)
                    Button("Open in Browser", action: openInBrowser)
                    Button("Close View") { destination = nil }
                        .disabled(destination == nil)
                }
                Text(status)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 900, minHeight: 650)
            .padding(.bottom, 10)
            .task {
                do {
                    cookies = try await MeetWebProbeSession.cookies()
                    status = cookies?.isEmpty == true
                        ? "No Meet-scoped cookies in Kibble's session. Use Open Meet to check sign-in."
                        : "Ready. Paste a Meet link. Leave the call in Meet before closing."
                } catch {
                    cookies = []
                    status = "Could not read Kibble's stored session."
                }
            }
        }

        private func openLink() {
            guard let url = MeetProbeLink.parse(link) else {
                status = "Enter a meet.google.com link or a meeting code."
                return
            }
            destination = url
        }

        private func openInBrowser() {
            guard let url = MeetProbeLink.parse(link) ?? destination else {
                status = "Enter a Meet link or open Meet first."
                return
            }
            status = NSWorkspace.shared.open(url)
                ? "Opened in your default browser."
                : "Could not open the link in your default browser."
        }
    }

    /// Only a Meet URL may be entered. The URL stays in the text field and never
    /// appears in a report or a log.
    enum MeetProbeLink {
        static func parse(_ input: String) -> URL? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let value = trimmed.contains("://") ? trimmed : "https://meet.google.com/\(trimmed)"
            guard let url = URL(string: value), url.scheme == "https", url.host == "meet.google.com",
                  url.port == nil, url.user == nil, url.password == nil,
                  url.path != "/", url.path != "/call"
            else { return nil }
            return url
        }
    }

    private struct MeetProbeWebView: NSViewRepresentable {
        let cookies: [MeetWebProbeCookie]
        let destination: URL?
        let status: @MainActor (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(status: status)
        }

        func makeNSView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.uiDelegate = context.coordinator
            view.navigationDelegate = context.coordinator
            context.coordinator.view = view
            context.coordinator.destination = destination
            Task { @MainActor in
                let jar = configuration.websiteDataStore.httpCookieStore
                var seeded = 0
                for seed in cookies {
                    let properties: [HTTPCookiePropertyKey: Any] = [
                        .name: seed.name, .value: seed.value, .domain: seed.domain,
                        .path: seed.path, .secure: "TRUE"
                    ]
                    if let cookie = HTTPCookie(properties: properties) {
                        await jar.setCookie(cookie)
                        seeded += 1
                    }
                }
                status("WebKit seeded \(seeded) of \(cookies.count) Meet-scoped cookies.")
                context.coordinator.ready = true
                context.coordinator.loadIfNeeded()
            }
            return view
        }

        func updateNSView(_: WKWebView, context: Context) {
            context.coordinator.destination = destination
            context.coordinator.loadIfNeeded()
        }

        static func dismantleNSView(_ view: WKWebView, coordinator _: Coordinator) {
            view.stopLoading()
            view.loadHTMLString("", baseURL: nil)
            view.navigationDelegate = nil
            view.uiDelegate = nil
        }

        @MainActor
        final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
            weak var view: WKWebView?
            var ready = false
            var destination: URL?
            private var loaded: URL?
            let status: @MainActor (String) -> Void

            init(status: @escaping @MainActor (String) -> Void) {
                self.status = status
            }

            func loadIfNeeded() {
                guard ready, let view, destination != loaded else { return }
                loaded = destination
                if let destination {
                    view.load(URLRequest(url: destination))
                    status("Opening Meet…")
                } else {
                    view.stopLoading()
                    view.loadHTMLString("", baseURL: nil)
                    status("Call view closed.")
                }
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                let host = webView.url?.host() ?? "page"
                status("Loaded \(host). Check the page above for Meet's compatibility result.")
            }

            func webView(
                _ webView: WKWebView,
                didFailProvisionalNavigation _: WKNavigation!,
                withError _: Error
            ) {
                status("Meet page failed to load.")
            }

            func webView(
                _ webView: WKWebView,
                createWebViewWith _: WKWebViewConfiguration,
                for navigationAction: WKNavigationAction,
                windowFeatures _: WKWindowFeatures
            ) -> WKWebView? {
                // Google sign-in may open a new window. Keep it in this temporary
                // view so a popup cannot disappear without feedback.
                if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                    webView.load(URLRequest(url: url))
                }
                return nil
            }
        }
    }
#endif
