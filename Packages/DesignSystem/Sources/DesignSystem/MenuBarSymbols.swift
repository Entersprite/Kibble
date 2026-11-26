/// The SF Symbols the menu bar's own items show, beside their titles as the
/// system's own items have them. Checked by `MenuBarSymbolsTests`, since a
/// wrong name compiles and draws nothing; the Conversation and Call menus
/// carry theirs in their own tables (`ConversationMenuBar`, `CallMenu`).
public enum MenuBarSymbols {
    /// File › New Message…, New Group Chat… and New Space…: the sidebar +
    /// menu's symbols for the same three (`ConversationSidebarTools`).
    public static let newMessage = "square.and.pencil"
    public static let newGroupChat = "person.3"
    public static let newSpace = "number"

    /// Kibble › About Kibble: the system's own About item shows this one,
    /// which replacing the item with Kibble's own panel would otherwise lose.
    public static let about = "info.circle"

    /// The Help menu: the source, the three documents and the diagnostics.
    public static let source = "chevron.left.forwardslash.chevron.right"
    public static let disclaimer = "exclamationmark.circle"
    public static let license = "text.document"
    public static let acknowledgments = "hands.clap"
    public static let exportDiagnostics = "square.and.arrow.up"

    /// The Accounts menu's commands. The accounts themselves carry a
    /// checkmark instead, as a window list does.
    public static let accountPanel = "person.2.circle"
    public static let addAccount = "person.crop.circle.badge.plus"
    public static let manageAccounts = "person.2.badge.gearshape"

    /// The menu bar item's menu: the sidebar's Mute and Unmute bells for
    /// pausing and resuming, and a window for opening the main one.
    public static let pauseNotifications = "bell.slash"
    public static let resumeNotifications = "bell"
    public static let openWindow = "macwindow"

    /// Edit › Find, the symbol the system's own Find submenu shows.
    public static let find = "magnifyingglass"

    static let all = [
        newMessage, newGroupChat, newSpace, about, source, disclaimer, license, acknowledgments,
        exportDiagnostics, accountPanel, addAccount, manageAccounts, pauseNotifications,
        resumeNotifications, openWindow, find
    ]
}
