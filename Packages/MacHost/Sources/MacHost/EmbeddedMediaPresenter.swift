import AppCore
import AppKit
import Foundation
import WebKit

enum EmbeddedMediaPolicy {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["www.youtube.com", "www.youtube-nocookie.com"].contains(url.host?.lowercased()),
              url.fragment == nil, url.query == nil,
              url.path.hasPrefix("/embed/") else { return false }
        let identifier = url.path.dropFirst("/embed/".count)
        return identifier.utf8.count == 11 && identifier.utf8.allSatisfy {
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57)
                .contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func request(_ url: URL, bundleID: String) -> URLRequest? {
        guard allows(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("https://" + bundleID.lowercased(), forHTTPHeaderField: "Referer")
        return request
    }
}

/// One explicit player for the process, with no login data or account cookies.
/// The original account owner alone can dismiss it during account teardown.
@MainActor
final class EmbeddedMediaPresenter: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = EmbeddedMediaPresenter()
    private var owner: ObjectIdentifier?
    private var window: NSWindow?
    private var webView: WKWebView?

    func open(_ url: URL, owner: ObjectIdentifier) {
        guard let request = EmbeddedMediaPolicy.request(
            url, bundleID: Bundle.main.bundleIdentifier ?? "com.entersprite.kibble"
        ) else { return }
        closeCurrent()
        self.owner = owner
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let player = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        player.title = "Video"
        player.contentMinSize = NSSize(width: 480, height: 270)
        player.isReleasedWhenClosed = false
        player.contentView = web
        player.delegate = self
        window = player
        webView = web
        player.center()
        player.makeKeyAndOrderFront(nil)
        web.load(request)
    }

    func close(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        closeCurrent()
    }

    private func closeCurrent() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        owner = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        closeCurrent()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard webView === self.webView, let url = action.request.url else { return .cancel }
        if action.targetFrame?.isMainFrame == true {
            if EmbeddedMediaPolicy.allows(url) || url.absoluteString == "about:blank" {
                return .allow
            }
            if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        return ["https", "about"].contains(url.scheme) ? .allow : .cancel
    }
}

public extension SystemLaunchServices {
    var embeddedMediaOpener: (@MainActor @Sendable (URL) -> Void)? {
        { [weak self] url in
            guard let self else { return }
            EmbeddedMediaPresenter.shared.open(url, owner: ObjectIdentifier(self))
        }
    }

    func closeEmbeddedMedia() {
        EmbeddedMediaPresenter.shared.close(owner: ObjectIdentifier(self))
    }
}

extension ServiceAccountLaunchServices {
    var embeddedMediaOpener: (@MainActor @Sendable (URL) -> Void)? {
        { [weak self] url in
            guard let self else { return }
            EmbeddedMediaPresenter.shared.open(url, owner: ObjectIdentifier(self))
        }
    }

    func closeEmbeddedMedia() {
        EmbeddedMediaPresenter.shared.close(owner: ObjectIdentifier(self))
    }
}
