import AppKit
import SwiftUI
import WebKit

@MainActor
final class AccountSignInWindow: NSObject, NSWindowDelegate {
    private let model: CookieCaptureModel
    private let canceled: () async -> Void
    private var window: NSWindow?
    private var closing = false

    init(model: CookieCaptureModel, canceled: @escaping () async -> Void) {
        self.model = model; self.canceled = canceled
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Connect Google Account"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AccountSignInContent(model: model))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    func close() {
        closing = true
        window?.close(); window = nil
    }

    func windowWillClose(_: Notification) {
        guard !closing else { return }
        Task { await canceled() }
    }
}

private struct AccountSignInContent: View {
    let model: CookieCaptureModel
    var body: some View {
        VStack(spacing: 0) {
            AccountSignInBrowser(model: model)
            Divider()
            HStack {
                Text(model.callSetup?.isActive == true ? model.callSetup?.status ?? model.status : model
                    .status)
                    .font(.callout)
                Spacer()
                if let setup = model.callSetup, setup.isActive {
                    Button("Try Again") { setup.retry() }.disabled(setup.isSaving || setup.isFinishing)
                    Button("Continue to Chat") { Task { await setup.continueToChat() } }
                        .disabled(setup.isFinishing)
                } else if model.showsManualControls {
                    Button("Capture") { model.capture() }
                    Button("Continue") { Task { await model.save() } }.disabled(!model.canSave)
                }
            }.padding(12)
        }.frame(minWidth: 760, minHeight: 560)
    }
}

private struct AccountSignInBrowser: NSViewRepresentable {
    let model: CookieCaptureModel
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = LoginWebViewConfiguration.chat.userAgent
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        let adapter = AccountLoginWebView(view)
        context.coordinator.adapter = adapter
        model.attach(adapter)
        view.load(URLRequest(url: LoginWebViewConfiguration.chat.startURL))
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}
    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: CookieCaptureModel
        var adapter: AccountLoginWebView?
        init(model: CookieCaptureModel) {
            self.model = model
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            if let adapter {
                model.pageSettled(adapter)
            }
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
private final class AccountLoginWebView: LoginWebView {
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
