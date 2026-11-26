import AppKit
import SwiftUI

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
        // The subtitle names the page's host, as an address bar would.
        let content = CallSignInRecoveryContent(model: model) { [weak window] host in
            window?.subtitle = host
        }
        window.contentView = NSHostingView(rootView: content)
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

/// None of the buttons takes Return, which belongs to the page's own form.
private struct CallSignInRecoveryContent: View {
    let model: CallSignInRecovery
    let pageHost: @MainActor (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LoginBrowser(recovering: model, pageHost: pageHost)
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
