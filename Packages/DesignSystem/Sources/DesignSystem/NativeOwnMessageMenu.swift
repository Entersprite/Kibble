#if os(macOS)
    import AppKit

    /// Edit… and Delete…, added at the top of the native text menu before the
    /// text's own items; `NativeReactionMenu` then puts the reactions above
    /// them (edit spec §5).
    @MainActor
    enum NativeOwnMessageMenu {
        static func insert(_ items: OwnMessageMenuItems?, into menu: NSMenu) -> NSMenu {
            guard let items else { return menu }
            var next = 0
            for (title, run) in [("Edit…", items.edit), ("Delete…", items.delete)] {
                guard let run else { continue }
                let trampoline = ReactionMenuTrampoline(run)
                let item = NSMenuItem(
                    title: title, action: #selector(ReactionMenuTrampoline.choose(_:)), keyEquivalent: ""
                )
                item.target = trampoline
                // `target` is weak: the item keeps the trampoline alive itself.
                item.representedObject = trampoline
                menu.insertItem(item, at: next)
                next += 1
            }
            menu.insertItem(.separator(), at: next)
            return menu
        }
    }
#endif
