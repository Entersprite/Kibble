#if os(macOS)
    import AppKit
    import ChatKit

    /// The reaction row, added to the menu a text view was about to show
    /// (native text menu spec §2). The text's own items (Copy, Look Up,
    /// Translate, Services) stay where `NSTextView` put them, below a
    /// separator.
    ///
    /// The row is a submenu with `presentationStyle = .palette`, which AppKit
    /// draws inline in place of the item holding it. A palette draws each
    /// item's image and drops its title (session 44 §7), so every item gets an
    /// `EmojiGlyph` and keeps its emoji as the title for VoiceOver.
    @MainActor
    enum NativeReactionMenu {
        static func insertReactions(
            into menu: NSMenu,
            message: Message,
            actions: ReactionActions?
        ) -> NSMenu {
            guard let actions, !message.isDeleted else { return menu }
            let palette = NSMenu(title: "React")
            palette.presentationStyle = .palette
            for item in QuickReactionItems.items(for: message.reactions) {
                palette.addItem(entry(item, message: message.id, actions: actions))
            }
            let holder = NSMenuItem(title: "React", action: nil, keyEquivalent: "")
            holder.submenu = palette
            menu.insertItem(holder, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        private static func entry(
            _ item: QuickReactionItem, message: Message.ID, actions: ReactionActions
        ) -> NSMenuItem {
            let trampoline = ReactionMenuTrampoline {
                actions.toggle(message, item.choice, item.adds)
            }
            let entry = NSMenuItem(
                title: item.emoji, action: #selector(ReactionMenuTrampoline.choose(_:)), keyEquivalent: ""
            )
            entry.target = trampoline
            // `target` is weak: the item keeps the trampoline alive itself.
            entry.representedObject = trampoline
            if let glyph = EmojiGlyph.image(for: item.emoji) {
                entry.image = NSImage(
                    cgImage: glyph,
                    size: NSSize(width: EmojiGlyph.side, height: EmojiGlyph.side)
                )
            }
            return entry
        }
    }

    /// An `NSMenuItem` action that runs a closure.
    @MainActor
    final class ReactionMenuTrampoline: NSObject {
        private let run: () -> Void

        init(_ run: @escaping () -> Void) {
            self.run = run
        }

        @objc func choose(_: Any?) {
            run()
        }
    }

    /// The native text menu without its editing items. `NSTextView` offers
    /// Cut, Paste, Font, Spelling and Substitutions even when it is read-only;
    /// a chat bubble keeps the items for reading it: Look Up, Translate, Copy,
    /// Share and Speech (session 45 review, Important 3). Recognised by action,
    /// never by title, which is localised.
    @MainActor
    enum ReadingTextMenu {
        static let editingActions: Set<String> = ["cut:", "paste:", "pasteAsPlainText:", "pasteAsRichText:"]

        /// A submenu is editing when any of its items opens one of these panels
        /// or toggles: the Font, Spelling and Grammar, and Substitutions menus.
        static let editingSubmenuActions: Set<String> = [
            "orderFrontFontPanel:", "showGuessPanel:", "orderFrontSubstitutionsPanel:"
        ]

        static func trimmed(_ menu: NSMenu) -> NSMenu {
            for item in menu.items.reversed() where isEditing(item) {
                menu.removeItem(item)
            }
            collapseSeparators(in: menu)
            return menu
        }

        private static func isEditing(_ item: NSMenuItem) -> Bool {
            if let action = item.action, editingActions.contains(NSStringFromSelector(action)) {
                return true
            }
            guard let submenu = item.submenu else { return false }
            return submenu.items.contains { entry in
                entry.action.map { editingSubmenuActions.contains(NSStringFromSelector($0)) } ?? false
            }
        }

        /// No separator first, last, or after another.
        private static func collapseSeparators(in menu: NSMenu) {
            var previousWasSeparator = true
            for item in menu.items {
                if item.isSeparatorItem, previousWasSeparator {
                    menu.removeItem(item)
                    continue
                }
                previousWasSeparator = item.isSeparatorItem
            }
            if let last = menu.items.last, last.isSeparatorItem {
                menu.removeItem(last)
            }
        }
    }
#endif
