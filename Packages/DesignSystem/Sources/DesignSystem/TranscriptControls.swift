import ChatKit
import SwiftUI

enum TranscriptLayout {
    /// The transcript's side padding; the floating button keeps the same
    /// margin.
    static let horizontalPadding: CGFloat = 16
}

/// What the floating Jump to Latest does, pure so each case is a test. It
/// shows while the newest loaded message's end is out of view, or while the
/// newest messages are not loaded at all - and then only when the host's
/// latest jump can fetch them (`newerMessagesAreLatestJump`). A window
/// trimmed below by paging up has no such jump: one more page down is not
/// the latest, so the button stays hidden rather than promise it.
enum TranscriptLatestJump {
    enum Action: Equatable {
        /// Scroll to the newest loaded message.
        case scroll
        /// Ask the host for the latest messages, as the list's own button does.
        case load
    }

    /// What the transcript says about its newest messages.
    struct Context: Equatable {
        var hasNewer = false
        var latestJump = false
        var canLoadNewer = false
        var loading = false
        var isEmpty = false
    }

    static func action(nearBottom: Bool, _ context: Context) -> Action? {
        guard !context.isEmpty, !context.loading else { return nil }
        if context.hasNewer {
            return context.latestJump && context.canLoadNewer ? .load : nil
        }
        return nearBottom ? nil : .scroll
    }
}

extension TranscriptLatestJump.Context {
    init(_ state: ChatSceneState, canLoadNewer: Bool) {
        hasNewer = state.hasNewerMessages
        latestJump = state.newerMessagesAreLatestJump
        self.canLoadNewer = canLoadNewer
        loading = state.isLoadingNewerMessages || state.isLoadingOlderMessages
        isEmpty = state.messages.isEmpty
    }
}

/// The floating Jump to Latest, above the typing row, in the transcript's own
/// bottom inset and never the toolbar's band (`CLAUDE.md`).
struct TranscriptJumpOverlay: ViewModifier {
    @Binding var nearBottom: Bool
    let context: TranscriptLatestJump.Context
    let perform: (TranscriptLatestJump.Action) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            JumpToLatestButton(nearBottom: $nearBottom, context: context, perform: perform)
                .padding(.trailing, TranscriptLayout.horizontalPadding)
                .padding(.bottom, 8)
        }
    }
}

/// An icon-only round glass button at the transcript's foot: a control
/// floating over content, which is what Liquid Glass is for. Always in the
/// view tree and faded rather than inserted, so showing it moves nothing.
///
/// It reads `nearBottom` itself, through the binding, so only it redraws as
/// the newest end comes and goes. Read in `MessageList`'s body, the same
/// state redrew the whole transcript in the middle of placing a search's
/// target, and the placement was lost (measured in the hosted transcript
/// tests).
struct JumpToLatestButton: View {
    static let symbol = "arrow.down"

    @Binding var nearBottom: Bool
    let context: TranscriptLatestJump.Context
    let perform: (TranscriptLatestJump.Action) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let action = TranscriptLatestJump.action(nearBottom: nearBottom, context)
        Button {
            if let action {
                perform(action)
            }
        } label: {
            Label("Jump to Latest", systemImage: Self.symbol)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Jump to Latest")
        .opacity(action == nil ? 0 : 1)
        .allowsHitTesting(action != nil)
        .accessibilityHidden(action == nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: action)
    }
}

/// Who is typing, at the transcript's foot: a fixed 36-point row wherever
/// the backend reports typing, so the indicator coming and going moves
/// nothing.
struct TranscriptTypingRow: View {
    let state: ChatSceneState

    var body: some View {
        if state.capabilities.receivesTypingState {
            HStack {
                let typists = ActivityPresentation.typists(state)
                if !typists.isEmpty {
                    TypingIndicator(
                        members: typists,
                        directory: state.directory,
                        namesVisible: state.selectedConversation?.kind != .directMessage
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
            .padding(.leading, 50).padding(.trailing, 16)
        }
    }
}

/// The two-second tint on the message a search opened (search spec §1.5).
/// `marked` is set once per open, so a later render of the same highlight
/// does not restart the mark, and opening it again does.
struct TranscriptSearchMark: ViewModifier {
    let state: ChatSceneState
    @Binding var marked: TranscriptScroll.Request?
    @Binding var markOn: Bool

    func body(content: Content) -> some View {
        content.task(id: TranscriptMarkTrigger(state)) {
            let request = state.highlightedMessage.map {
                TranscriptScroll.Request(id: $0, generation: state.searchOpenGeneration)
            }
            guard TranscriptMark.shouldMark(request, in: state.messages, marked: marked) else {
                return
            }
            let justMarked = request
            marked = justMarked
            await TranscriptMark.fade(
                on: { withAnimation(.easeIn(duration: 0.15)) { markOn = true } },
                sleep: { try await Task.sleep(for: .seconds(2)) },
                isStillMarked: { marked == justMarked },
                off: { withAnimation(.easeOut(duration: 0.6)) { markOn = false } }
            )
        }
    }
}

/// The transcript's VoiceOver rotors: the messages that mention you, and
/// those with links, each entry scrolling to its row. Built only when
/// VoiceOver asks for them.
struct TranscriptRotors: ViewModifier {
    let messages: [Message]
    let me: Member.ID?
    let directory: [Member.ID: Member]

    func body(content: Content) -> some View {
        content
            .accessibilityRotor("Mentions") {
                ForEach(Self.mentioningMe(messages, me: me), id: \.id) { message in
                    AccessibilityRotorEntry(
                        Text(Self.label(for: message, directory: directory)),
                        id: message.id
                    )
                }
            }
            .accessibilityRotor("Links") {
                ForEach(Self.withLinks(messages), id: \.id) { message in
                    AccessibilityRotorEntry(
                        Text(Self.label(for: message, directory: directory)),
                        id: message.id
                    )
                }
            }
    }

    nonisolated static func mentioningMe(_ messages: [Message], me: Member.ID?) -> [Message] {
        messages.filter { message in
            !message.isDeleted && MentionHighlight.ranges(
                in: message.text,
                mentions: message.mentions,
                me: me
            )
            .contains { $0.isMe }
        }
    }

    nonisolated static func withLinks(_ messages: [Message]) -> [Message] {
        messages.filter { !$0.isDeleted && !$0.links.isEmpty }
    }

    /// "Alex Lee: the first words of the message".
    nonisolated static func label(for message: Message, directory: [Member.ID: Member]) -> String {
        let words = message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let excerpt = words.count > 80 ? String(words.prefix(80)) + "…" : words
        let sender = Display.name(of: message.sender, in: directory)
        return excerpt.isEmpty ? sender : "\(sender): \(excerpt)"
    }
}
