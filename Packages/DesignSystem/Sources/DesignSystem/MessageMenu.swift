import ChatKit
import SwiftUI

/// The SF Symbols of a message's menus, named once so the SwiftUI menu, the
/// native text menu and `MessageMenuTests` read the same strings (`CLAUDE.md`:
/// an SF Symbol name is an unchecked string).
enum MessageMenuSymbols {
    static let quoteReply = "arrowshape.turn.up.left"
    static let forward = "arrowshape.turn.up.right"
    static let replyInThread = ThreadsPresentation.replySymbol
    static let markUnread = ThreadsPresentation.markUnreadSymbol
    static let openLink = "safari"
    static let copyLink = "link"
    static let edit = "pencil"
    static let delete = "trash"
    static let moreEmoji = EmojiPickerModel.addSymbol

    // What the attachment menus add for the file or picture under the pointer.
    static let quickLook = "eye"
    static let open = "arrow.up.forward.app"
    static let showInFinder = "folder"
    static let download = "arrow.down.circle"
    static let cancelDownload = "xmark.circle"
    static let saveAs = "square.and.arrow.down"
    static let copyImage = "doc.on.doc"

    static let all = [
        quoteReply, forward, replyInThread, markUnread, openLink, copyLink, edit, delete, moreEmoji,
        quickLook, open, showInFinder, download, cancelDownload, saveAs, copyImage
    ]
}

/// One item of a message's menu: what it says, its picture and what it does.
struct MessageMenuEntry {
    let title: String
    let symbol: String
    var isDestructive = false
    let run: () -> Void
}

/// A message's menu items in the one order every menu draws them: the link
/// under the pointer (Open Link, Copy Link), then the message's own items
/// (Quote Reply, Forward…, Reply in Thread, Mark as Unread), then Edit… and
/// Delete… last. The SwiftUI context menu, the native text menu and the
/// row's VoiceOver actions are all built from this, so they cannot drift
/// apart (edit spec §5, threads spec §5, links spec §7.3).
struct MessageMenuTable {
    let link: [MessageMenuEntry]
    let message: [MessageMenuEntry]
    let editing: [MessageMenuEntry]

    init(own: OwnMessageMenuItems?, link url: URL? = nil, openLink: @escaping (URL) -> Void = { _ in }) {
        link = url.map { url in
            [
                MessageMenuEntry(title: "Open Link", symbol: MessageMenuSymbols.openLink) { openLink(url) },
                MessageMenuEntry(title: "Copy Link", symbol: MessageMenuSymbols.copyLink) {
                    LinkPasteboard.copy(url)
                }
            ]
        } ?? []
        message = [
            Self.entry("Quote Reply", MessageMenuSymbols.quoteReply, own?.quote),
            Self.entry("Forward…", MessageMenuSymbols.forward, own?.forward),
            Self.entry("Reply in Thread", MessageMenuSymbols.replyInThread, own?.replyInThread),
            Self.entry("Mark as Unread", MessageMenuSymbols.markUnread, own?.markUnread)
        ].compactMap(\.self)
        editing = [
            own?.edit.map { MessageMenuEntry(title: "Edit…", symbol: MessageMenuSymbols.edit, run: $0) },
            own?.delete.map {
                MessageMenuEntry(
                    title: "Delete…",
                    symbol: MessageMenuSymbols.delete,
                    isDestructive: true,
                    run: $0
                )
            }
        ].compactMap(\.self)
    }

    /// An item, where the host offers its action.
    private static func entry(_ title: String, _ symbol: String, _ run: (() -> Void)?) -> MessageMenuEntry? {
        run.map { MessageMenuEntry(title: title, symbol: symbol, run: $0) }
    }

    /// The non-empty sections, in order; a separator goes between each.
    var sections: [[MessageMenuEntry]] {
        [link, message, editing].filter { !$0.isEmpty }
    }

    var isEmpty: Bool {
        link.isEmpty && message.isEmpty && editing.isEmpty
    }
}

/// What a bubble's menus act on. A view nested in a bubble whose own context
/// menu replaces the row's (a file chip, a picture, forwarded text) carries
/// this, so its menu keeps the row's reactions and items and they act on the
/// row's message, as a link card's already did (links spec §7.3).
struct MessageMenuContext {
    let message: Message
    let reactions: ReactionActions?
    let own: OwnMessageMenuItems?
    /// Opens the full picker ("More Emoji…"); `nil` draws no such item.
    var onMore: (() -> Void)?

    /// A menu with nothing of the row's: a card drawn outside any bubble
    /// still offers its own link's items.
    static func empty(_ message: Message) -> MessageMenuContext {
        MessageMenuContext(message: message, reactions: nil, own: nil)
    }

    /// Whether the row offers anything at all: a deleted message offers
    /// nothing, and neither does a backend that can neither react nor act.
    var offersItems: Bool {
        (reactions != nil || own != nil) && !message.isDeleted
    }

    func table(link: URL? = nil, openLink: @escaping (URL) -> Void = { _ in }) -> MessageMenuTable {
        MessageMenuTable(own: message.isDeleted ? nil : own, link: link, openLink: openLink)
    }
}

/// The SwiftUI menu's contents: the quick reactions as one palette row and
/// More Emoji…, then the thing under the pointer (`target`, when
/// `hasTarget`), then the table's sections, each after a separator.
struct MessageMenuContent<Target: View>: View {
    /// `nil` for a view drawn outside any row: its menu is `target` alone.
    let context: MessageMenuContext?
    let table: MessageMenuTable
    /// The link the table's first section is for: Share follows its Copy Link.
    var sharedLink: URL?
    var hasTarget = false
    @ViewBuilder let target: () -> Target

    private var reactions: ReactionActions? {
        context?.message.isDeleted == false ? context?.reactions : nil
    }

    var body: some View {
        if let reactions, let context {
            QuickReactionPalette(message: context.message, actions: reactions)
            if let onMore = context.onMore {
                Button("More Emoji…", systemImage: MessageMenuSymbols.moreEmoji, action: onMore)
            }
        }
        if hasTarget {
            if reactions != nil {
                Divider()
            }
            target()
        }
        ForEach(Array(table.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 || reactions != nil || hasTarget {
                Divider()
            }
            ForEach(section, id: \.title) { entry in
                Button(
                    entry.title, systemImage: entry.symbol, role: entry.isDestructive ? .destructive : nil,
                    action: entry.run
                )
            }
            if index == 0, !table.link.isEmpty, let sharedLink {
                ShareLink(item: sharedLink)
            }
        }
    }
}

extension MessageMenuContent where Target == EmptyView {
    init(context: MessageMenuContext?, table: MessageMenuTable, sharedLink: URL? = nil) {
        self.init(context: context, table: table, sharedLink: sharedLink, hasTarget: false) { EmptyView() }
    }
}

extension MessageMenuContent {
    /// A nested view's menu: the row's reactions, `target` (the file or
    /// picture under the pointer), then the row's items acting on the row's
    /// message.
    init(nestedIn context: MessageMenuContext?, @ViewBuilder target: @escaping () -> Target) {
        self.init(
            context: context, table: context?.table() ?? MessageMenuTable(own: nil), hasTarget: true,
            target: target
        )
    }
}

/// The quick set as one palette row (`ControlGroup` + `.palette`, macOS 14+).
struct QuickReactionPalette: View {
    let message: Message
    let actions: ReactionActions

    var body: some View {
        ControlGroup {
            ForEach(
                QuickReactionItems.items(for: message.reactions, recents: actions.recents()),
                id: \.emoji
            ) { item in
                Button {
                    actions.toggle(message.id, item.choice, item.adds)
                } label: {
                    // The palette draws the icon and drops the title, so the
                    // emoji goes in as a picture; the title stays for
                    // VoiceOver (`EmojiGlyph`).
                    Label {
                        Text(item.emoji)
                    } icon: {
                        if let glyph = EmojiGlyph.image(for: item.emoji) {
                            Image(decorative: glyph, scale: EmojiGlyph.scale)
                                .renderingMode(.original)
                        }
                    }
                }
            }
        }
        .controlGroupStyle(.palette)
    }
}

/// The bubble's context menu, and the menu of anything nested in it that
/// replaces the row's (a link card adds Open Link and Copy Link through
/// `link`). Applied unconditionally, with the decision inside the builder:
/// a modifier that returned `content` in one branch and `content.contextMenu`
/// in the other rebuilt the bubble whenever its inputs flipped, which a send
/// finishing or a backend's reactions arriving both do (`CLAUDE.md`).
struct ReactionMenu: ViewModifier {
    let context: MessageMenuContext
    var link: URL?
    @Environment(\.openURL) private var openURL

    init(context: MessageMenuContext, link: URL? = nil) {
        self.context = context
        self.link = link
    }

    init(
        message: Message, actions: ReactionActions?, own: OwnMessageMenuItems?,
        onMore: (() -> Void)? = nil, link: URL? = nil
    ) {
        self.init(
            context: MessageMenuContext(message: message, reactions: actions, own: own, onMore: onMore),
            link: link
        )
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            if context.offersItems || link != nil, !context.message.isDeleted {
                MessageMenuContent(
                    context: context, table: context.table(link: link) { openURL($0) }, sharedLink: link
                )
            }
        }
    }
}

extension View {
    /// The row's menu items as VoiceOver actions, in the menu's order, with
    /// Add Reaction first where the picker can open (spec rule: actions are
    /// metadata, silent unless VoiceOver is on).
    func messageAccessibilityActions(_ table: MessageMenuTable, addReaction: (() -> Void)?) -> some View {
        accessibilityActions {
            if let addReaction {
                Button("Add Reaction", action: addReaction)
            }
            ForEach(Array(table.sections.joined().enumerated()), id: \.offset) { _, entry in
                Button(entry.title, action: entry.run)
            }
        }
    }
}
