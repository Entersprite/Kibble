import SwiftUI

/// Every keyboard shortcut Kibble's own menu bar commands bind, in one table.
///
/// SwiftUI gives a shortcut to the first menu item that claims it and drops
/// it from any later one without a word: a second ⌘F item placed after the
/// system's Find… showed no shortcut at all (measured in a menu-bar probe).
/// A clash therefore fails nothing and shows only as a command that stopped
/// answering its keys. Binding through this table is what lets a test prove
/// that no two commands share a shortcut, the composer's format keys and the
/// system's included (`MenuBarShortcutsTests`).
///
/// An item with no convention to follow gets no shortcut rather than an
/// invented one: Show Details, Call, Go to Mentions and the call's camera
/// and sharing have none.
public enum MenuBarShortcuts {
    /// Edit › Find › Search…, the key every Mac app finds with.
    public static let search = KeyboardShortcut("f")
    /// Next and Previous Result, the keys of Find Next and Find Previous.
    public static let nextResult = KeyboardShortcut("g")
    public static let previousResult = KeyboardShortcut("g", modifiers: [.command, .shift])

    /// File › New Message… and New Group Chat…; New Space… has none.
    public static let newMessage = KeyboardShortcut("n")
    public static let newGroupChat = KeyboardShortcut("n", modifiers: [.command, .shift])

    /// Window › Kibble, which brings the main window back after it was closed.
    public static let mainWindow = KeyboardShortcut("0")
    /// Accounts › Show Account Panel, beside the accounts' Control-Command digits.
    public static let accountPanel = KeyboardShortcut("0", modifiers: [.control, .command])

    /// View › Back and Forward, the keys Safari, Finder and Slack step with.
    public static let back = KeyboardShortcut("[")
    public static let forward = KeyboardShortcut("]")

    /// Conversation › Next and Previous Conversation: Control-Tab and
    /// Control-Shift-Tab, the keys that step through tabs and conversations.
    public static let nextConversation = KeyboardShortcut(.tab, modifiers: .control)
    public static let previousConversation = KeyboardShortcut(.tab, modifiers: [.control, .shift])
    /// Conversation › Mark as Read, Mail's key for the same command.
    public static let markAsRead = KeyboardShortcut("u", modifiers: [.command, .shift])

    /// Call › Mute and Unmute. Go to Mentions has no shortcut, so the two
    /// never compete for Shift-Command-M.
    public static let muteCall = KeyboardShortcut("m", modifiers: [.command, .shift])

    /// The nth account in the Accounts menu, Control-Command-1 to 9; `nil` past
    /// the ninth.
    public static func account(_ index: Int) -> KeyboardShortcut? {
        digit(index).map { KeyboardShortcut($0, modifiers: [.control, .command]) }
    }

    /// The nth conversation down the sidebar, Command-1 to Command-9; `nil`
    /// past the ninth.
    public static func conversation(_ index: Int) -> KeyboardShortcut? {
        digit(index).map { KeyboardShortcut($0) }
    }

    private static func digit(_ index: Int) -> KeyEquivalent? {
        (0 ..< 9).contains(index) ? KeyEquivalent(Character(String(index + 1))) : nil
    }

    /// Everything Kibble binds itself, the composer field's format keys included.
    public static var all: [KeyboardShortcut] {
        [
            search, nextResult, previousResult, newMessage, newGroupChat, mainWindow, accountPanel,
            back, forward, nextConversation, previousConversation, markAsRead, muteCall
        ]
            + (0 ..< 9).compactMap(account) + (0 ..< 9).compactMap(conversation)
            + ComposerFormat.keyed.compactMap(\.shortcut)
    }

    /// What the system and SwiftUI already bind in the menus of every Mac app
    /// built like this one, read from such an app's menu bar: Settings, Hide,
    /// Hide Others, Quit, the Edit menu's undo and pasteboard items, Close,
    /// Close All, Minimize, Toggle Sidebar, Enter Full Screen, Emoji & Symbols
    /// and Help. None of Kibble's own may take one of these.
    static let system: [KeyboardShortcut] = [
        KeyboardShortcut(","),
        KeyboardShortcut("h"),
        KeyboardShortcut("h", modifiers: [.option, .command]),
        KeyboardShortcut("q"),
        KeyboardShortcut("z"),
        KeyboardShortcut("z", modifiers: [.shift, .command]),
        KeyboardShortcut("x"),
        KeyboardShortcut("c"),
        KeyboardShortcut("v"),
        KeyboardShortcut("a"),
        KeyboardShortcut("w"),
        KeyboardShortcut("w", modifiers: [.option, .command]),
        KeyboardShortcut("m"),
        KeyboardShortcut("s", modifiers: [.option, .command]),
        KeyboardShortcut("f", modifiers: [.control, .command]),
        KeyboardShortcut(.space, modifiers: [.control, .command]),
        KeyboardShortcut("?")
    ]
}
