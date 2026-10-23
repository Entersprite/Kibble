import SwiftUI
#if os(macOS)
    import AppKit
#endif

extension View {
    /// Opens a resizable sheet at `ideal` and keeps it at least `minimum`,
    /// reporting the size the person leaves it at.
    ///
    /// SwiftUI sizes a sheet only for the content it was presented with. The
    /// conversation panel presents Loading first and swaps Info in when the
    /// details arrive, and that swap neither grows the window nor makes it
    /// resizable: Info was laid out at its minimum inside Loading's window,
    /// clipped. So the sheet's window is sized here, once per appearance.
    /// Apply it outside the content's frame, so it measures what Info is given.
    func sheetWindowSizing(
        minimum: CGSize,
        ideal: CGSize,
        resized: @escaping (CGSize) -> Void
    ) -> some View {
        #if os(macOS)
            background(SheetWindowSizer(minimum: minimum, ideal: ideal, resized: resized))
        #else
            self
        #endif
    }
}

#if os(macOS)
    private struct SheetWindowSizer: NSViewRepresentable {
        let minimum: CGSize
        let ideal: CGSize
        let resized: (CGSize) -> Void

        func makeNSView(context _: Context) -> SheetSizerView {
            SheetSizerView()
        }

        func updateNSView(_ view: SheetSizerView, context _: Context) {
            view.minimum = minimum
            view.ideal = ideal
            view.resized = resized
        }

        static func dismantleNSView(_ view: SheetSizerView, coordinator _: ()) {
            view.release()
        }
    }

    /// Sizes the sheet window it sits in, and hands the window back as it was
    /// when the content goes, so Loading, Preview and creation keep their sizes.
    final class SheetSizerView: NSView {
        var minimum = CGSize.zero
        var ideal = CGSize.zero
        var resized: (CGSize) -> Void = { _ in }

        /// The sizer that last sized each window. A replacement (Info for
        /// another conversation) can appear before the one it replaces goes.
        private static let owners = NSMapTable<NSWindow, SheetSizerView>.weakToWeakObjects()
        private weak var sheet: NSWindow?
        private var original: (mask: NSWindow.StyleMask, minimum: CGSize)?
        /// The sheet's own bars around the content, such as the button bar.
        private var chrome = CGSize.zero
        private var scheduled = false
        private var minimumObservation: NSKeyValueObservation?
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                release()
            } else {
                schedule()
            }
        }

        override func layout() {
            super.layout()
            schedule()
        }

        /// Sizes on the next turn, once SwiftUI has laid the content out.
        private func schedule() {
            guard sheet == nil, !scheduled, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                open()
            }
        }

        private func open() {
            // Only a sheet: renders host the same content in a plain window.
            guard sheet == nil, let window, window.isSheet || window.sheetParent != nil,
                  let host = window.contentView, bounds.width > 0, bounds.height > 0 else { return }
            sheet = window
            if let previous = Self.owners.object(forKey: window), previous !== self {
                original = previous.original
            } else {
                original = (window.styleMask, window.contentMinSize)
            }
            Self.owners.setObject(self, forKey: window)
            chrome = chrome(in: host)
            let target = Self.clamp(ideal, minimum, limit(for: window)) + chrome
            window.styleMask.insert(.resizable)
            let current = window.contentRect(forFrameRect: window.frame).size
            // A sheet on its way out, or not yet shown, keeps its size.
            let shown = window.isVisible && window.sheetParent?.attachedSheet === window
            if shown, abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 {
                // AppKit places a resized sheet on its parent itself. Setting
                // its frame instead makes AppKit move the parent window.
                window.setContentSize(target)
            }
            // SwiftUI resets the minimum whenever it updates the window, even
            // mid-resize, so it is held here. Only the person's own resize is
            // remembered, never a size measured while the window was settling.
            holdMinimum()
            minimumObservation = window.observe(\.contentMinSize) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.holdMinimum() }
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.remember() }
            }
        }

        private func holdMinimum() {
            let held = minimum + chrome
            if let sheet, sheet.contentMinSize != held {
                sheet.contentMinSize = held
            }
        }

        private func remember() {
            guard let sheet else { return }
            let content = sheet.contentRect(forFrameRect: sheet.frame).size - chrome
            resized(Self.clamp(content, minimum, limit(for: sheet)))
        }

        /// Gives the window back as it was before this content sized it.
        func release() {
            minimumObservation = nil
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            guard let sheet else { return }
            self.sheet = nil
            guard Self.owners.object(forKey: sheet) === self else { return }
            Self.owners.removeObject(forKey: sheet)
            if let original {
                if !original.mask.contains(.resizable) {
                    sheet.styleMask.remove(.resizable)
                }
                sheet.contentMinSize = original.minimum
            }
        }

        /// The bars around the content, measured from where it sits in the
        /// sheet: at the top left, or centered when the window is too small.
        private func chrome(in host: NSView) -> CGSize {
            let rect = convert(bounds, to: host)
            let size = host.bounds.size
            let top = host.isFlipped ? rect.minY : size.height - rect.maxY
            return CGSize(
                width: max(size.width - 2 * min(rect.minX, 0) - rect.width, 0),
                height: max(size.height - 2 * min(top, 0) - rect.height, 0)
            )
        }

        /// The largest content the screen can show below the top of the
        /// parent's content area, where a sheet taller than its parent hangs,
        /// so the sheet's own buttons stay above the Dock. A sheet on no
        /// screen gets the main screen's size, or a sane bound without one.
        private func limit(for window: NSWindow) -> CGSize {
            let parent = window.sheetParent
            let top = parent.map { $0.convertToScreen($0.contentLayoutRect).maxY } ?? window.frame.maxY
            let anchor = NSPoint(x: window.frame.midX, y: top - 1)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) else {
                let size = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1600, height: 1200)
                return size - chrome
            }
            let visible = screen.visibleFrame
            let below = NSRect(
                x: 0, y: 0, width: visible.width,
                height: max(min(top, visible.maxY) - visible.minY, 0)
            )
            return window.contentRect(forFrameRect: below).size - chrome
        }

        private static func clamp(_ size: CGSize, _ minimum: CGSize, _ maximum: CGSize) -> CGSize {
            CGSize(
                width: max(min(size.width, maximum.width), minimum.width),
                height: max(min(size.height, maximum.height), minimum.height)
            )
        }
    }

    private func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }

    private func - (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
    }
#endif
