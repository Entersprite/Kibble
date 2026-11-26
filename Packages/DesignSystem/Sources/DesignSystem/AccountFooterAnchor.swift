import Observation
import SwiftUI

/// Where the sidebar's bottom row sits, so `AccountShell` can draw the account
/// pill and its panel above the whole window.
///
/// The pill cannot live inside the sidebar: the panel grows past it over the
/// conversation, and the sidebar's hosting view would clip it. The split view's
/// columns are separate hosting views, so `.global` frames from one are not
/// comparable with another's. Both ends measure in window coordinates instead.
@MainActor
@Observable
final class AccountFooterGeometry {
    /// The pill row, in window coordinates; `.zero` until the sidebar lays out.
    var row: CGRect = .zero
}

extension EnvironmentValues {
    /// Present under `AccountShell`: the sidebar reserves the footer's room and
    /// reports it, and the shell draws the pill.
    @Entry var accountFooter: AccountFooterGeometry?
}

/// The sidebar's bottom row under `AccountShell`: as tall as the pill row, so
/// rows soften under it as before, and drawing nothing itself.
struct AccountFooterAnchor: View {
    let geometry: AccountFooterGeometry

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: SidebarFooter.controlSize)
            .background(WindowFrameReader { geometry.row = $0 })
            // The same insets `SidebarFooter` uses, so the pill keeps its place.
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

#if os(macOS)
    /// Reports this view's frame in window coordinates (origin bottom left),
    /// again whenever it moves, resizes or the window resizes.
    struct WindowFrameReader: NSViewRepresentable {
        let onChange: (CGRect) -> Void

        func makeNSView(context: Context) -> FrameReportingView {
            let view = FrameReportingView()
            view.onChange = onChange
            return view
        }

        func updateNSView(_ view: FrameReportingView, context: Context) {
            view.onChange = onChange
            view.scheduleReport()
        }
    }

    final class FrameReportingView: NSView {
        var onChange: ((CGRect) -> Void)?
        private var last = CGRect.null
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReport() }
            }
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleReport()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleReport()
        }

        /// Asynchronous, so a report never writes observed state during the
        /// layout pass that produced it.
        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        private func report() {
            guard window != nil else { return }
            let rect = convert(bounds, to: nil)
            guard rect != last else { return }
            last = rect
            onChange?(rect)
        }
    }
#else
    /// No window-level overlay on this platform yet: reports nothing, so the
    /// shell draws no pill.
    struct WindowFrameReader: View {
        let onChange: (CGRect) -> Void
        var body: some View {
            Color.clear
        }
    }
#endif
