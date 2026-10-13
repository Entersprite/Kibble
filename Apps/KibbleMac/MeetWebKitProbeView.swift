#if DEBUG
    import AppKit
    import Foundation
    import MacHost
    import SwiftUI
    import WebKit

    /// A temporary Meet sign-in and media view. It neither creates a meeting
    /// nor rings anyone: the person decides what to open and whether to join.
    @MainActor
    struct MeetWebKitProbeView: View {
        @State private var cookies: [MeetWebProbeCookie]?
        @State private var link = ""
        @State private var destination: URL?
        @State private var status = "Loading the stored session…"
        @State private var cookieStore: WKHTTPCookieStore?
        @State private var meetPageLoaded = false
        @State private var isSaving = false

        var body: some View {
            VStack(spacing: 0) {
                if let cookies {
                    MeetProbeWebView(
                        cookies: cookies, destination: destination,
                        onCookieStore: { cookieStore = $0 },
                        onLoadedHost: { meetPageLoaded = $0 == "meet.google.com" },
                        status: { status = $0 }
                    )
                } else {
                    ProgressView("Preparing Meet…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 10) {
                    TextField("Meet link or meeting code", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(openLink)
                    Button("Open Chat") { destination = URL(string: "https://chat.google.com/") }
                        .disabled(isSaving)
                    Button("Open Meet") { destination = URL(string: "https://meet.google.com/") }
                        .disabled(isSaving)
                    Button("Save Meet Sign-In", action: saveMeetSignIn)
                        .disabled(!meetPageLoaded || cookieStore == nil || isSaving)
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
                        ? "No Meet-scoped cookies in Kibble's session. Open Meet to sign in."
                        : "Open Chat in this view, then Open Meet and save the Meet sign-in."
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

        private func saveMeetSignIn() {
            guard let cookieStore, meetPageLoaded, !isSaving else { return }
            isSaving = true
            status = "Checking the Chat accounts…"
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    let captured = await cookieStore.allCookies()
                    let count = try await MeetWebProbeSession.saveMeetCookies(captured)
                    status = count == 0
                        ? "No Meet-host cookies were saved. Finish Meet sign-in, then try again."
                        : "Saved \(count) Meet-host cookies. Close this window, then rerun the Resolve probe."
                } catch let error as MeetWebProbeSaveError {
                    switch error {
                    case let .accountVerificationFailed(detail):
                        status = "\(detail) Nothing was saved."
                    case .accountMismatch:
                        status = "Meet is signed into a different Google account. Nothing was saved."
                    case .sessionChangedDuringVerification:
                        status = "The Chat session changed during verification. Try saving again."
                    }
                } catch {
                    status = "Could not save Meet sign-in. The Chat session was left unchanged."
                }
            }
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
        let onCookieStore: @MainActor (WKHTTPCookieStore) -> Void
        let onLoadedHost: @MainActor (String?) -> Void
        let status: @MainActor (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onLoadedHost: onLoadedHost, status: status)
        }

        func makeNSView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.customUserAgent = LoginWebViewConfiguration.chat.userAgent
            view.uiDelegate = context.coordinator
            view.navigationDelegate = context.coordinator
            context.coordinator.view = view
            context.coordinator.destination = destination
            Task { @MainActor in onCookieStore(configuration.websiteDataStore.httpCookieStore) }
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
            let onLoadedHost: @MainActor (String?) -> Void
            let status: @MainActor (String) -> Void

            init(
                onLoadedHost: @escaping @MainActor (String?) -> Void,
                status: @escaping @MainActor (String) -> Void
            ) {
                self.onLoadedHost = onLoadedHost
                self.status = status
            }

            func loadIfNeeded() {
                guard ready, let view, destination != loaded else { return }
                loaded = destination
                onLoadedHost(nil)
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
                let host = webView.url?.host()
                onLoadedHost(host)
                switch host {
                case "meet.google.com":
                    status("Meet loaded. Save Meet Sign-In when the account shown is correct.")
                case "chat.google.com":
                    status("Chat loaded. Confirm your Chat account, then Open Meet and save the sign-in.")
                default:
                    status("Loaded \(host ?? "page"). Continue sign-in in the page above.")
                }
            }

            func webView(
                _ webView: WKWebView,
                didFailProvisionalNavigation _: WKNavigation!,
                withError _: Error
            ) {
                onLoadedHost(nil)
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
