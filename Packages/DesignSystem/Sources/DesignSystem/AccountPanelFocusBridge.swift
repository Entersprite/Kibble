#if os(macOS)
    import AppKit
    import SwiftUI

    /// The panel is an overlay, so dismissing it restores its original field.
    /// A different account or a detached view must never receive the old focus.
    struct AccountPanelFocusBridge: NSViewRepresentable {
        let isOpen: Bool
        let accountID: String?

        func makeNSView(context _: Context) -> FocusView {
            FocusView()
        }

        func updateNSView(_ view: FocusView, context _: Context) {
            view.update(open: isOpen, account: accountID)
        }

        final class FocusView: NSView {
            private weak var previous: NSResponder?
            private var opened = false
            private var account: String?

            func update(open: Bool, account: String?) {
                guard open != opened else { return }
                opened = open
                if open {
                    previous = window?.firstResponder
                    self.account = account
                } else {
                    defer { previous = nil }
                    guard account == self.account, let window,
                          window.attachedSheet == nil, let previous,
                          let previousView = previous as? NSView,
                          previousView.window === window else { return }
                    window.makeFirstResponder(previous)
                }
            }
        }
    }
#endif
