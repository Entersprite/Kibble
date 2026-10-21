import ChatKit
import SwiftUI

public struct ComposerQuoteRequest: Equatable, Sendable {
    public let id = UUID()
    public let quote: MessageQuote

    public init(message: Message) {
        quote = MessageQuote(message: message)
    }
}

struct MessageQuotePreview: View {
    let quote: MessageQuote
    let directory: [Member.ID: Member]
    var cancel: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(directory[quote.sender]?.displayName ?? "Message")
                    .font(.caption.weight(.semibold))
                Text(quote.isDeleted ? "Message deleted" : quote.text.isEmpty ? "Attachment" : quote.text)
                    .font(.callout)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let cancel {
                Button(action: cancel) {
                    Label("Cancel Reply", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// The composer's format button. Its items show the Format menu's shortcuts,
/// and carry them only while this composer's field has the keyboard
/// (`showsShortcuts`), so that with the thread's composer open beside the
/// conversation's, a Cmd-B can only reach the field that has the keyboard,
/// whether the menu bar or a button answers it. (Measured on macOS 27, a
/// closed `Menu`'s pop-up holds no items, so today only the menu bar does.)
struct ComposerFormattingButton: View {
    var showsShortcuts = false
    let choose: (ComposerFormat) -> Void

    var body: some View {
        Menu {
            ForEach(ComposerFormat.allCases) { format in
                if format == .code {
                    Divider()
                }
                Button(format.title) { choose(format) }
                    .keyboardShortcut(showsShortcuts ? format.shortcut : nil)
            }
        } label: {
            Label("Format", systemImage: "textformat").labelStyle(.iconOnly)
                .foregroundStyle(.primary)
                .frame(width: ComposerLayout.lineHeight, height: ComposerLayout.lineHeight)
                .contentShape(.circle)
        }
        // A plain pull-down with no indicator, so the label alone fills the
        // glass circle, as the + and emoji buttons beside it do. A borderless
        // button style drew a chevron beside the label, which widened the
        // button and left the circle small and off its center.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Format selected text")
    }
}
