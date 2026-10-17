import AppKit
import LocalBridgeBackend
import SwiftUI
import WebKit

@MainActor
final class CallSignInRecoveryWindow: NSObject, NSWindowDelegate {
    private let model: CallSignInRecovery
    private var window: NSWindow?
    private var closing = false

    init(model: CallSignInRecovery) {
        self.model = model
    }

    func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Set Up Calls"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: CallSignInRecoveryContent(model: model))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        closing = true
        window?.close()
        window = nil
    }

    func windowWillClose(_: Notification) {
        guard !closing else { return }
        Task { await model.finish(restart: true) }
    }
}

private struct CallSignInRecoveryContent: View {
    let model: CallSignInRecovery
    var body: some View {
        VStack(spacing: 0) {
            CallSignInRecoveryBrowser(model: model)
            Divider()
            HStack {
                Text(model.status).font(.callout)
                Spacer()
                Button("Try Again") { model.retry() }.disabled(model.isWorking)
                Button("Close") { Task { await model.finish(restart: true) } }
            }.padding(12)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct CallSignInRecoveryBrowser: NSViewRepresentable {
    let model: CallSignInRecovery

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = LoginWebViewConfiguration.chat.userAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        let adapter = RecoveryLoginWebView(view)
        context.coordinator.adapter = adapter
        model.attach(adapter) { seeds in
            for seed in seeds {
                guard let cookie = HTTPCookie(properties: [
                    .name: seed.name, .value: seed.value, .domain: seed.domain,
                    .path: seed.path, .secure: "TRUE"
                ]) else { continue }
                await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}
    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: CallSignInRecovery
        var adapter: RecoveryLoginWebView?
        init(model: CallSignInRecovery) {
            self.model = model
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            if let adapter {
                model.pageSettled(adapter)
            }
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) {
            model.navigationFailed()
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: any Error) {
            model.navigationFailed()
        }

        func webView(
            _ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

@MainActor
private final class RecoveryLoginWebView: LoginWebView {
    let view: WKWebView
    init(_ view: WKWebView) {
        self.view = view
    }

    var currentURL: URL? {
        view.url
    }

    var currentTitle: String? {
        view.title
    }

    func allCookies() async -> [HTTPCookie] {
        await view.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    func navigate(to url: URL) {
        view.load(URLRequest(url: url))
    }
}
