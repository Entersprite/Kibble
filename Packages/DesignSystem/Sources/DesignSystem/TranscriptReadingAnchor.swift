import ChatKit
import SwiftUI

/// Geometry for realized rows only. Mutating this bookkeeping never publishes
/// presentation state or invalidates the whole transcript during scrolling.
@MainActor
final class TranscriptReadingAnchor {
    private var frames: [Message.ID: CGRect] = [:]
    private var pending: (id: Message.ID, offset: CGFloat)?
    private var restoring = false
    private var correcting = false
    private var correctionQueued = false
    private var generation = 0

    #if os(macOS)
        weak var scrollView: NSScrollView?
    #endif

    func record(_ id: Message.ID, frame: CGRect) {
        frames[id] = frame
        guard correcting, pending?.id == id, !correctionQueued else { return }
        correctionQueued = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            correctOffset()
        }
    }

    func cancel() {
        generation += 1
        pending = nil
        restoring = false
        correcting = false
        correctionQueued = false
    }

    func discardUnusedCapture() {
        if !restoring {
            cancel()
        }
    }

    func beginCorrection() {
        guard let pending else { return }
        frames.removeValue(forKey: pending.id)
        correcting = true
    }

    var restoringID: Message.ID? {
        restoring ? pending?.id : nil
    }

    private func correctOffset() {
        guard restoring, let pending, let frame = frames[pending.id] else { return }
        #if os(macOS)
            guard let scrollView else { return }
            let delta = frame.minY - pending.offset
            self.pending = nil
            restoring = false
            correcting = false
            correctionQueued = false
            guard abs(delta) > 0.5 else { return }
            var origin = scrollView.contentView.bounds.origin
            origin.y += delta
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
            self.pending = nil
            restoring = false
            correcting = false
            correctionQueued = false
        #endif
    }

    func forget(_ id: Message.ID) {
        frames.removeValue(forKey: id)
    }

    func capture() {
        guard pending == nil else { return }
        if let first = frames.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) {
            generation += 1
            pending = (first.key, first.value.minY)
        }
    }

    func restore(in messages: [Message]) -> Message.ID? {
        capture()
        guard let pending, messages.contains(where: { $0.id == pending.id }) else {
            pending = nil
            return nil
        }
        restoring = true
        return pending.id
    }
}

struct TranscriptAnchorTracking: ViewModifier {
    let id: Message.ID
    let anchor: TranscriptReadingAnchor

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { anchor.record(
                id,
                frame: $0
            ) }
            .onDisappear { anchor.forget(id) }
    }
}

#if os(macOS)
    import AppKit

    /// Supplies the native clip view solely for restoring the within-row
    /// offset after a stable-ID scroll. The cache never retains this view.
    struct TranscriptScrollBridge: NSViewRepresentable {
        let anchor: TranscriptReadingAnchor

        func makeNSView(context _: Context) -> Locator {
            let view = Locator()
            view.anchor = anchor
            return view
        }

        func updateNSView(_ view: Locator, context _: Context) {
            view.anchor = anchor
        }

        final class Locator: NSView {
            var anchor: TranscriptReadingAnchor?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                anchor?.scrollView = enclosingScrollView
            }
        }
    }
#endif
