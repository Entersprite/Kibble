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

    /// The player window's title: the video's own, from its page, once the
    /// page has one.
    static func windowTitle(_ pageTitle: String?) -> String {
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Video" : title
    }
}

/// One explicit player for the process, with no login data or account cookies.
/// The original account owner alone can dismiss it during account teardown.
///
/// The window resizes to any shape, and opens where the last one was left. The player's own full-screen button works. Nothing
/// plays until the person presses play.
@MainActor
final class EmbeddedMediaPresenter: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = EmbeddedMediaPresenter()
    static let frameName = "EmbeddedVideo"
    private var owner: ObjectIdentifier?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var titleObservation: NSKeyValueObservation?

    func open(_ url: URL, owner: ObjectIdentifier) {
        guard let request = EmbeddedMediaPolicy.request(
            url, bundleID: Bundle.main.bundleIdentifier ?? "com.entersprite.kibble"
        ) else { return }
        closeCurrent()
        self.owner = owner
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        web.navigationDelegate = self
        let player = Self.makeWindow()
        player.contentView = web
        player.delegate = self
        window = player
        webView = web
        if !player.setFrameUsingName(Self.frameName) {
            player.center()
        }
        player.setFrameAutosaveName(Self.frameName)
        titleObservation = web.observe(\.title, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.webView else { return }
                self.window?.title = EmbeddedMediaPolicy.windowTitle(web.title)
            }
        }
        player.makeKeyAndOrderFront(nil)
        web.load(request)
    }

    /// No website data kept, and no playback the person did not start.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    static func makeWindow() -> NSWindow {
        let player = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        player.title = EmbeddedMediaPolicy.windowTitle(nil)
        // Free to resize to any shape: a portrait or 4:3 video must not be
        // letterboxed into a fixed one (owner decision).
        player.contentMinSize = NSSize(width: 480, height: 270)
        player.tabbingMode = .disallowed
        player.isReleasedWhenClosed = false
        return player
    }

    func close(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        closeCurrent()
    }

    private func closeCurrent() {
        titleObservation?.invalidate()
        titleObservation = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        // Hands the saved frame's name to the next player, which may open
        // before this window is gone.
        window?.setFrameAutosaveName("")
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
