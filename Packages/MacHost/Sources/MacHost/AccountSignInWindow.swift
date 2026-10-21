import AppKit
import SwiftUI

@MainActor
final class AccountSignInWindow: NSObject, NSWindowDelegate {
    private let model: CookieCaptureModel
    /// "Add Google Account", or "Reconnect ‹account›" for an account signing in again.
    private let title: String
    private let canceled: () async -> Void
    private var window: NSWindow?
    private var closing = false

    init(
        model: CookieCaptureModel,
        title: String = "Add Google Account",
        canceled: @escaping () async -> Void
    ) {
        self.model = model; self.title = title; self.canceled = canceled
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The subtitle names the page's host, as an address bar would.
        let content = AccountSignInContent(model: model) { [weak window] host in
            window?.subtitle = host
        }
        window.contentView = NSHostingView(rootView: content)
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
    let pageHost: @MainActor (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LoginBrowser(capturing: model, pageHost: pageHost)
            Divider()
            HStack {
                Text(model.visibleStatus)
                    .font(.callout)
                Spacer()
                CookieCaptureButtons(model: model)
            }.padding(12)
        }.frame(minWidth: 760, minHeight: 560)
    }
}
