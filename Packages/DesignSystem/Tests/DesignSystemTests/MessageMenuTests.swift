#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import Testing
    @testable import DesignSystem

    /// One table drives the SwiftUI menu, the native text menu and the row's
    /// VoiceOver actions: the link under the pointer, the message's items,
    /// then Edit… and Delete… last (edit spec §5).
    @MainActor
    struct MessageMenuTests {
        private static let me = Member.ID("u-me")
        private static let link = URL(string: "https://example.com/plan")!

        private static func message(sender: Member.ID = me, isReply: Bool = false) -> Message {
            Message(
                id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                threadID: MessageThread.ID("t-1"), sender: sender, text: "see https://example.com/plan",
                createdAt: Date(timeIntervalSince1970: 0), isReply: isReply
            )
        }

        private final class Calls {
            var names: [String] = []
        }

        private static func everything(_ calls: Calls) -> OwnMessageMenuItems {
            OwnMessageMenuItems(
                edit: { calls.names.append("edit") }, delete: { calls.names.append("delete") },
                replyInThread: { calls.names.append("reply") }, markUnread: { calls.names.append("unread") },
                quote: { calls.names.append("quote") }, forward: { calls.names.append("forward") }
            )
        }

        private static func titles(_ menu: NSMenu) -> [String] {
            menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        @Test func theOrderIsLinkThenMessageThenEditAndDeleteLast() {
            let table = MessageMenuTable(own: Self.everything(Calls()), link: Self.link)
            #expect(table.sections.map { $0.map(\.title) } == [
                ["Open Link", "Copy Link"],
                ["Quote Reply", "Forward…", "Reply in Thread", "Mark as Unread"],
                ["Edit…", "Delete…"]
            ])
            #expect(table.editing.last?.isDestructive == true)
            #expect(table.sections.joined().filter(\.isDestructive).map(\.title) == ["Delete…"])
        }

        @Test func itemsActOnTheirOwnHandlersAndOpenLinkOpensTheLink() {
            let calls = Calls()
            var opened: [URL] = []
            let table = MessageMenuTable(own: Self.everything(calls), link: Self.link) { opened.append($0) }
            for entry in table.sections.joined() where entry.title != "Copy Link" {
                entry.run()
            }
            #expect(opened == [Self.link])
            #expect(calls.names == ["quote", "forward", "reply", "unread", "edit", "delete"])
        }

        @Test func emptySectionsAreDropped() {
            #expect(MessageMenuTable(own: nil).isEmpty)
            #expect(MessageMenuTable(own: nil).sections.isEmpty)
            #expect(MessageMenuTable(own: nil, link: Self.link).sections.map { $0.map(\.title) } == [
                ["Open Link", "Copy Link"]
            ])
        }

        /// The native menu draws the table in the same order and sections,
        /// every item with its symbol, before the text's own items.
        @Test func theNativeMenuDrawsTheSameTable() {
            let table = MessageMenuTable(own: Self.everything(Calls()), link: Self.link)
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            let result = NativeOwnMessageMenu.insert(table, into: menu)
            #expect(Self.titles(result) == [
                "Open Link", "Copy Link", "-",
                "Quote Reply", "Forward…", "Reply in Thread", "Mark as Unread", "-",
                "Edit…", "Delete…", "-", "Copy"
            ])
            let items = result.items.filter { !$0.isSeparatorItem && $0.title != "Copy" }
            #expect(items.allSatisfy { $0.image != nil })
            #expect(zip(items.map(\.title), table.sections.joined().map(\.title)).allSatisfy { $0 == $1 })
        }

        @Test func everySymbolExists() {
            let names = MessageMenuSymbols.all + [JumpToLatestButton.symbol, EmojiCategorySymbols.fallback]
                + EmojiCategorySymbols.byTitle.values.sorted()
            for name in names {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }

        /// The text view's own link items go: the table's replace them, and
        /// Open With would open a link without `LinkPolicy`.
        @Test func theTextViewsOwnLinkItemsAreRemoved() {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(
                title: "Open Link", action: NSSelectorFromString("_openLinkFromMenu:"), keyEquivalent: ""
            ))
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = NSMenu(title: "Open With")
            menu.addItem(openWith)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Copy Link",
                action: NSSelectorFromString("copyLink:"),
                keyEquivalent: ""
            ))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: ""))
            menu.addItem(NSMenuItem(
                title: "Quick Look", action: NSSelectorFromString("toggleQuickLookPreviewPanel:"),
                keyEquivalent: ""
            ))
            #expect(Self.titles(ReadingTextMenu.trimmed(menu)) == ["Copy"])
        }

        @Test func theLinkUnderThePointerIsFoundAndChecked() {
            let text = NSMutableAttributedString(string: "see https://example.com/plan or javascript:x")
            text.addAttribute(.link, value: Self.link, range: NSRange(location: 4, length: 24))
            text.addAttribute(.link, value: "javascript:x", range: NSRange(location: 32, length: 12))
            typealias Coordinator = MessageTextView.Coordinator
            #expect(Coordinator.link(in: text, at: 10) == Self.link)
            #expect(Coordinator.link(in: text, at: 0) == nil)
            #expect(Coordinator.link(in: text, at: 35) == nil, "a refused scheme offers no Open Link")
            #expect(Coordinator.link(in: text, at: 99) == nil)
            #expect(Coordinator.link(in: nil, at: 0) == nil)
        }

        /// The real text view, right-clicked on a link: the reactions, then
        /// the table's Open Link and Copy Link, once each, then Edit… and
        /// Delete…, then the text's own reading items.
        @Test func aRightClickOnALinkInARealTextView() throws {
            let message = Self.message()
            let calls = Calls()
            let coordinator = MessageTextView.Coordinator(
                message: message, actions: ReactionActions { _, _, _ in },
                own: OwnMessageMenuItems(edit: { calls.names.append("edit") }, delete: nil)
            )
            let view = BubbleTextView.make()
            view.delegate = coordinator
            let text = NSMutableAttributedString(
                string: message.text, attributes: [.font: NSFont.preferredFont(forTextStyle: .body)]
            )
            text.addAttribute(.link, value: Self.link, range: NSRange(location: 4, length: 24))
            view.show(text)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
            let window = NSWindow(
                contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = view
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: view.convert(NSPoint(x: 60, y: 10), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let titles = try Self.titles(#require(view.menu(for: event)))
            #expect(Array(titles.prefix(7)) == ["React", "-", "Open Link", "Copy Link", "-", "Edit…", "-"])
            #expect(titles.filter { $0 == "Open Link" }.count == 1)
            #expect(titles.filter { $0 == "Copy Link" }.count == 1)
            #expect(!titles.contains("Open With"))
            #expect(titles.contains("Copy"))
            withExtendedLifetime(window) {}
        }
    }
#endif
