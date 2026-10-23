import ChatKit
import SwiftUI

/// The pins' one tint and symbol, so the floating row, the transcript's
/// outline and the menus agree. The tint is kept to the row's glass and the
/// outline; the glyphs beside messages and in rows stay neutral.
enum PinStyle {
    static let symbol = "pin.fill"
    static let tint = Color.yellow
    static let outline = tint.opacity(0.5)
    /// Between a message and its pin glyph.
    static let glyphGap: CGFloat = 6

    /// The row's capsules, a little stronger under the highlight.
    static func glass(highlighted: Bool) -> Glass {
        .regular.tint(tint.opacity(highlighted ? 0.45 : 0.28)).interactive()
    }

    /// The disclosed list's one surface, the capsules' tint; its rows are not glass.
    static var panelGlass: Glass {
        .regular.tint(tint.opacity(0.28))
    }
}

/// What the pin row's one highlight can rest on.
enum PinRowTarget: Hashable {
    case message(Message.ID)
    /// The pin/count button that discloses the remaining previews.
    case more
    /// Retry after a failed refresh.
    case retry
}

/// The keyboard's order through the row, then the disclosed previews below
/// it: the arrows step one target and stop at either end, as a menu does.
struct PinRowNavigation {
    let row: [PinRowTarget]
    let list: [PinRowTarget]

    var first: PinRowTarget? {
        row.first ?? list.first
    }

    /// From nothing, or from a target that has since gone, the first.
    func move(from target: PinRowTarget?, forward: Bool) -> PinRowTarget? {
        let order = row + list
        guard let target, let index = order.firstIndex(of: target) else { return order.first }
        let next = index + (forward ? 1 : -1)
        return order.indices.contains(next) ? order[next] : target
    }
}

/// What a preview says and what VoiceOver reads for it.
enum PinnedPreviewSpeech {
    /// One line of the message: its words, else its first file's name, else
    /// its first card's title.
    static func preview(of message: Message) -> String {
        if !message.text.isEmpty {
            return message.text.replacingOccurrences(of: "\n", with: " ")
        }
        if let name = message.attachments.first?.name {
            return name
        }
        return message.cards.first?.header?.title.plainText ?? "Pinned message"
    }

    /// "Pinned message from Alex Lee, 3:25 PM: Release checklist".
    static func label(for message: Message, directory: [Member.ID: Member], me: Member.ID?) -> String {
        let author = message.sender == me ? "You" : Display.name(of: message.sender, in: directory)
        return "Pinned message from \(author), \(Display.timestamp(of: message.createdAt)): "
            + preview(of: message)
    }
}

/// Conversation › Show Pinned Messages, published by the pin row while its
/// window is in front. Equal while it is for the same conversation and as
/// available, so the menu bar is not rebuilt on every render; `show` sets the
/// row's own state, which an earlier render's closure reaches as well.
struct PinnedMessagesCommand: Equatable {
    let scope: AccountScoped<Conversation.ID?>
    let isAvailable: Bool
    let show: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.isAvailable == rhs.isAvailable
    }
}

extension FocusedValues {
    @Entry var pinnedMessages: PinnedMessagesCommand?
}

/// The menu bar's way to the pins: it puts the keyboard on the row, with the
/// first preview highlighted. No shortcut, as no convention names one
/// (`MenuBarShortcuts`).
public struct PinnedMessagesMenuItem: View {
    @FocusedValue(\.pinnedMessages) private var pins

    public init() {}

    public var body: some View {
        Button("Show Pinned Messages", systemImage: PinStyle.symbol) { pins?.show() }
            .disabled(pins?.isAvailable != true)
    }
}

/// A capsule of the pin row: callout text on the pins' tinted glass.
/// In the disclosed panel (`inPanel`) a row is no glass of its own: the panel
/// is the surface, and the highlight is a plain fill, as a menu's row is.
struct PinGlassButtonStyle: ButtonStyle {
    var highlighted = false
    var inPanel = false
    @ScaledMetric(relativeTo: .callout) private var lineHeight = 18

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .frame(height: lineHeight)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .background {
                Capsule().fill(Color.primary.opacity(inPanel && highlighted ? 0.1 : 0))
            }
            .glassEffect(inPanel ? .identity : PinStyle.glass(highlighted: highlighted), in: .capsule)
    }
}
