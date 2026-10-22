import SwiftUI

/// Whether a transcript follows its newest message or the person is reading
/// back through it. Only the person moves it between the two: a scroll of
/// theirs that leaves the end stops following, and one that comes back to
/// the end, or Jump to Newest, follows again.
///
/// Nothing the transcript does by itself stops it following: a message
/// arriving, a row growing as its picture, preview or reactions arrive, the
/// saved copy giving way to confirmed rows, or the column changing size with
/// the window, the thread panel or the composer. While it follows, each of
/// those puts the end back at the bottom (`TranscriptFollowing`).
///
/// Observable so that only the jump button, which reads it, redraws when it
/// changes. A list hands it on and never reads it in its body.
@MainActor
@Observable
final class TranscriptFollow {
    private(set) var isFollowing = true
    /// The person is scrolling: a wheel, a trackpad, the keyboard or the
    /// scroller.
    @ObservationIgnored private(set) var isScrolling = false

    /// A scroll of the person's that stops this close to the end follows
    /// again: about a line of text.
    nonisolated static let reach: CGFloat = 16

    func follow() {
        if !isFollowing {
            isFollowing = true
        }
    }

    func detach() {
        if isFollowing {
            isFollowing = false
        }
    }

    /// Measured on macOS 27: a wheel, a trackpad and Page Up or Down each
    /// report `interacting`; a scroll the list makes, none.
    func scrollPhase(_ phase: ScrollPhase) {
        isScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
    }

    enum Effect: Equatable {
        case follow
        case detach
        /// Put the end back at the bottom.
        case pin
    }

    /// What a change to the transcript's geometry means.
    ///
    /// Only a scroll of the person's decides between following and reading
    /// back: it follows exactly when it ends at the end. Everything else is
    /// the transcript's own doing, including scrolls it did not ask for (the
    /// scroll view puts back its old offset after a resize): while following,
    /// the end goes back to the bottom; while reading back, it follows again
    /// once the end is in view.
    ///
    /// `canFollow` is false while the newest messages are not loaded, and
    /// `settled` while something else is placing the transcript: its first
    /// placement, a jump to a message, an older page's anchor or a jump to the
    /// newest.
    nonisolated static func effect(
        following: Bool, scrolling: Bool, canFollow: Bool, settled: Bool, at end: TranscriptEnd
    ) -> Effect? {
        let atEnd = canFollow && end.distance <= reach
        if scrolling {
            return following == atEnd ? nil : atEnd ? .follow : .detach
        }
        if following {
            guard canFollow else { return .detach }
            return settled && end.distance > 0.5 ? .pin : nil
        }
        return settled && atEnd ? .follow : nil
    }
}

/// Where a transcript's end is against its viewport, from the scroll view's
/// geometry.
struct TranscriptEnd: Equatable {
    /// The content's height, and the viewport's size and insets: what a
    /// scroll leaves alone.
    struct Sizes: Equatable {
        var content: CGFloat = 0
        var container = CGSize.zero
        var insets = EdgeInsets()
    }

    var sizes = Sizes()
    /// How far the end of the content lies below the viewport's bottom; 0
    /// while it is in view.
    var distance: CGFloat

    init(sizes: Sizes = Sizes(), distance: CGFloat) {
        self.sizes = sizes
        self.distance = distance
    }

    /// The visible rect spans the whole viewport, the composer's inset
    /// included, and the content ends above that inset (measured: the
    /// container size leaves both insets out).
    init(_ geometry: ScrollGeometry) {
        sizes = Sizes(
            content: geometry.contentSize.height, container: geometry.containerSize,
            insets: geometry.contentInsets
        )
        distance = max(
            0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        )
    }
}

/// The last view in a transcript's stack, carrying its bottom margin, so a
/// scroll to it reaches the very end: a scroll to the newest message stops
/// that margin short.
struct TranscriptEndMarker: View {
    static let id = "transcript-end"

    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .id(Self.id)
            .accessibilityHidden(true)
    }
}

/// Keeps a transcript's end at the bottom while it follows, and tells the
/// person's scrolls from the changes the transcript makes by itself
/// (`TranscriptFollow.effect`).
struct TranscriptFollowing: ViewModifier {
    struct Conditions {
        var canFollow = true
        var settled = true
    }

    let follow: TranscriptFollow
    let proxy: ScrollViewProxy
    /// Read when the geometry changes, so it is never a render old.
    let conditions: () -> Conditions
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                follow.scrollPhase(phase)
            }
            .onScrollGeometryChange(for: TranscriptEnd.self, of: { geometry in
                TranscriptEnd(geometry)
            }, action: { old, new in
                let conditions = conditions()
                // VoiceOver moves the transcript to what it reads without a
                // scroll phase: with it running, a scroll that no change of
                // size explains is the person's.
                let scrolling = follow.isScrolling || (voiceOver && old.sizes == new.sizes)
                switch TranscriptFollow.effect(
                    following: follow.isFollowing, scrolling: scrolling,
                    canFollow: conditions.canFollow, settled: conditions.settled, at: new
                ) {
                case .follow?:
                    follow.follow()
                case .detach?:
                    follow.detach()
                case .pin?:
                    proxy.scrollTo(TranscriptEndMarker.id, anchor: .bottom)
                case nil:
                    break
                }
            })
    }
}
