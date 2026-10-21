#if os(macOS)
    import AppKit

    /// The message's items, from the same `MessageMenuTable` as the SwiftUI
    /// menu, added at the top of the native text menu before the text's own
    /// items: the link under the pointer, then Quote Reply, Forward…, Reply
    /// in Thread and Mark as Unread, then Edit… and Delete… last, each section
    /// after a separator and every item with its symbol. `NativeReactionMenu`
    /// then puts the reactions above them (edit spec §5, threads spec §5).
    @MainActor
    enum NativeOwnMessageMenu {
        static func insert(_ items: OwnMessageMenuItems?, into menu: NSMenu) -> NSMenu {
            insert(MessageMenuTable(own: items), into: menu)
        }

        static func insert(_ table: MessageMenuTable, into menu: NSMenu) -> NSMenu {
            guard !table.isEmpty else { return menu }
            var next = 0
            for (index, section) in table.sections.enumerated() {
                if index > 0 {
                    menu.insertItem(.separator(), at: next)
                    next += 1
                }
                for entry in section {
                    menu.insertItem(item(entry), at: next)
                    next += 1
                }
            }
            menu.insertItem(.separator(), at: next)
            return menu
        }

        static func item(_ entry: MessageMenuEntry) -> NSMenuItem {
            let trampoline = ReactionMenuTrampoline(entry.run)
            let item = NSMenuItem(
                title: entry.title, action: #selector(ReactionMenuTrampoline.choose(_:)), keyEquivalent: ""
            )
            item.target = trampoline
            // `target` is weak: the item keeps the trampoline alive itself.
            item.representedObject = trampoline
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            return item
        }
    }
#endif
