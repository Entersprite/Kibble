import ChatKit
import SwiftUI

/// The third column: the open thread, or nothing while it is collapsed.
extension ChatWindow {
    /// Whether the thread column is open: a panel, the thread actions to draw
    /// it with, and its conversation on screen. Mentions and the Threads list
    /// take the conversation's place, and the thread goes with it, as it did
    /// when the panel sat beside the transcript.
    var threadColumnShown: Bool {
        !state.showingMentions && !state.threads.showingList && state.selectedConversation != nil
            && offeredThreadActions != nil && state.threads.panel != nil
    }

    /// The column's content. Its title is a bar raised into the column's own
    /// titlebar section, so it blurs the replies under it, as AppKit's title
    /// does the transcript's; Follow and Close are toolbar items in the same
    /// section (`ThreadColumnBridge` puts a flexible space before them).
    @ViewBuilder var threadColumn: some View {
        if threadColumnShown, let threads = offeredThreadActions, let panel = state.threads.panel {
            Color.clear
                .overlay {
                    ThreadPanel(
                        panel: panel, state: state, actions: actions, threads: threads,
                        own: { panelHandlers(for: $0) }, editing: panelEditing(), dropStage: panelDropStage,
                        band: threadBand
                    )
                }
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { threadBand = $0 }
                .toolbar {
                    // Their own glass, the composer's, not the toolbar's capsule
                    // (session 63).
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: ComposerLayout.spacing) {
                            ThreadFollowButton(panel: panel, threads: threads)
                            ThreadCloseButton(threads: threads)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        } else {
            Color.clear
        }
    }
}

/// The thread column's width, pure, so each case is a test. AppKit's split
/// view keeps the column's width while it is open and drags its divider;
/// this decides only the width the column reopens at.
enum ThreadColumnLayout {
    /// Neither the conversation nor the thread is drawn narrower than this
    /// while there is room for both (session 58's minimum).
    static let minimumWidth: CGFloat = 260

    /// The thread's width when it opens: the width it last had, or half of
    /// what the conversation and the thread share, clamped so both keep the
    /// minimum. Below room for both minimums, each gets half.
    static func openingWidth(available: CGFloat, remembered: CGFloat?) -> CGFloat {
        guard available > 0 else { return 0 }
        let minimum = min(minimumWidth, available / 2)
        let wanted = remembered ?? (available / 2).rounded()
        return min(max(wanted, minimum), available - minimum)
    }
}
