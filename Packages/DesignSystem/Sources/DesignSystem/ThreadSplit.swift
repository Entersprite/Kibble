import ChatKit
import SwiftUI

/// How the transcript and the thread share the width (session 58): half and
/// half when a thread first opens, then wherever the person drags the
/// divider. Pure, so each case is a test.
struct ThreadSplitLayout: Equatable {
    /// The panel's share when a thread first opens.
    static let initialShare: CGFloat = 0.5
    /// Neither side is drawn narrower while there is room for both.
    static let minimumWidth: CGFloat = 260
    static let dividerWidth: CGFloat = 1

    let transcript: CGFloat
    let panel: CGFloat

    /// `share` is the panel's part of the width the divider leaves. Below
    /// room for both minimums, each side gets half.
    init(total: CGFloat, share: CGFloat) {
        let available = max(0, total - Self.dividerWidth)
        let minimum = min(Self.minimumWidth, available / 2)
        panel = min(max((available * share).rounded(), minimum), available - minimum)
        transcript = available - panel
    }

    /// The share a divider dragged to `position` (from the split's leading
    /// edge) leaves the panel, clamped as the layout clamps it. What a drag
    /// stores is what is drawn, so a drag past a minimum does not come back
    /// when the window grows.
    static func share(dividerAt position: CGFloat, total: CGFloat) -> CGFloat {
        let available = total - dividerWidth
        guard available > 0 else { return initialShare }
        return ThreadSplitLayout(total: total, share: (available - position) / available).panel / available
    }
}

/// The thread panel beside the transcript (threads spec §5.2, changed in
/// session 58). **Not an `.inspector`.** On macOS 26 an inspector floats over
/// the transcript, which keeps clear of it through a safe-area inset; with one
/// open, a live resize looped the window's layout until AppKit threw
/// (session 58). A plain split hands nothing back through an inset.
///
/// **The transcript is always the first child, with its frame always
/// applied**, never behind an `if`: a branch would give the whole transcript
/// chain two identities, the main composer included, and `threads` can change
/// without the conversation changing (the first world load after the v13
/// upgrade turns `repliesEnabled` on). The composer would be rebuilt, losing
/// its draft and its edit without `ended()`.
struct ThreadSplit: ViewModifier {
    let state: ChatSceneState
    let actions: ChatSceneActions
    /// `ChatWindow.offeredThreadActions`: no panel, so no reply composer, in
    /// a conversation without replies.
    let threads: ThreadActions?
    let own: (Message) -> OwnMessageHandlers?
    let editing: ComposerEditing?
    /// Where a drop on the panel goes (`ChatWindow.panelDropStage`).
    let dropStage: (([URL]) -> Void)?
    /// The panel's share, the window's for as long as it is open.
    @Binding var share: CGFloat
    /// The conversation's title and subtitle, which the split draws itself
    /// while it owns the title (`ownsTitle`).
    let title: String
    let subtitle: String
    let sidebarShown: Bool

    /// Shown only with a panel to draw and the thread actions to draw it with.
    var isPresented: Bool {
        threads != nil && state.threads.panel != nil
    }

    /// Whether the conversation's title is drawn here, in its own column,
    /// rather than by AppKit, whose title spans the detail column and runs a
    /// long name under the thread's (session 63). Only with the band there to
    /// draw it in, and the sidebar shown: collapsed, AppKit's title starts past
    /// the window's buttons, at a place SwiftUI cannot read, and the wider
    /// transcript needs a longer name to reach the panel.
    func ownsTitle(band: CGFloat) -> Bool {
        isPresented && band > 0 && sidebarShown
    }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let layout = ThreadSplitLayout(total: proxy.size.width, share: share)
            let band = proxy.safeAreaInsets.top
            HStack(spacing: 0) {
                content
                    .frame(width: isPresented ? layout.transcript : proxy.size.width)
                    // Always applied, so the transcript keeps its identity.
                    .overlay(alignment: .topLeading) {
                        if ownsTitle(band: band) {
                            ColumnTitle(title: title, subtitle: subtitle)
                                .padding(.leading, ColumnTitle.inset)
                                .padding(.trailing, 12)
                                .frame(width: layout.transcript, height: band, alignment: .leading)
                                .offset(y: -band)
                                .allowsHitTesting(false)
                        }
                    }
                if let threads, let panel = state.threads.panel {
                    ThreadSplitDivider(share: $share, total: proxy.size.width, position: layout.transcript)
                        // Through the toolbar's band too, between the two titles.
                        .ignoresSafeArea(.container, edges: .top)
                        // Above the panel, so the grip's half over it still takes the drag.
                        .zIndex(1)
                    ThreadPanel(
                        panel: panel, state: state, actions: actions, threads: threads,
                        own: own, editing: editing, dropStage: dropStage, band: band
                    )
                    .frame(width: layout.panel)
                }
            }
            .toolbar(removing: ownsTitle(band: band) ? .title : nil)
            .toolbar {
                // AppKit's title is what pushed the buttons to the trailing
                // edge; without it they sat beside the sidebar button.
                if ownsTitle(band: band) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                }
                if let threads, let panel = state.threads.panel {
                    ToolbarItem(placement: .primaryAction) {
                        ThreadPanelButtons(panel: panel, threads: threads)
                    }
                }
            }
        }
    }
}

/// A hairline with a wider grip. The drag moves the divider from where it
/// was when the drag began, so grabbing the grip off center does not jump.
struct ThreadSplitDivider: View {
    @Binding var share: CGFloat
    let total: CGFloat
    /// Where the divider sits: the transcript's width.
    let position: CGFloat
    @State private var origin: CGFloat?

    /// How far the grip reaches past the hairline on each side.
    static let gripWidth: CGFloat = 9
    /// How far one VoiceOver adjustment moves the divider.
    static let accessibilityStep: CGFloat = 0.05

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: ThreadSplitLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: Self.gripWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(drag)
            }
            .accessibilityElement()
            .accessibilityLabel("Thread divider")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    share = min(1, share + Self.accessibilityStep)
                case .decrement:
                    share = max(0, share - Self.accessibilityStep)
                @unknown default:
                    break
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = origin ?? position
                origin = start
                share = ThreadSplitLayout.share(dividerAt: start + value.translation.width, total: total)
            }
            .onEnded { _ in origin = nil }
    }
}
