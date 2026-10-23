import SwiftUI
import Testing
@testable import DesignSystem

/// SwiftUI drops a shortcut from every menu item after the first that claims
/// it, silently, so a clash shows only as a dead key. Every shortcut Kibble
/// binds comes from `MenuBarShortcuts`, and these prove no two collide.
struct MenuBarShortcutsTests {
    @Test func noTwoOfKibblesCommandsShareAShortcut() {
        let all = MenuBarShortcuts.all
        #expect(all.count == 35)
        #expect(Set(all).count == all.count)
    }

    @Test func noneTakesAShortcutTheSystemAlreadyBinds() {
        let system = MenuBarShortcuts.system
        #expect(Set(system).count == system.count)
        #expect(Set(MenuBarShortcuts.all).isDisjoint(with: system))
    }

    /// The pairs the menus' design had to keep apart.
    @Test func theKnownNeighborsStayApart() {
        let italic = ComposerFormat.italic.shortcut
        #expect(italic == KeyboardShortcut("i"))
        #expect(MenuBarShortcuts.all.filter { $0 == italic }.count == 1)
        #expect(MenuBarShortcuts.muteCall == KeyboardShortcut("m", modifiers: [.command, .shift]))
        #expect(MenuBarShortcuts.all.filter { $0 == MenuBarShortcuts.muteCall }.count == 1)
        #expect(MenuBarShortcuts.mainWindow != MenuBarShortcuts.accountPanel)
        #expect(MenuBarShortcuts.markAsRead != ComposerFormat.underline.shortcut)
    }

    @Test func theDigitsCoverOneToNineAndNothingElse() {
        #expect(MenuBarShortcuts.conversation(0) == KeyboardShortcut("1"))
        #expect(MenuBarShortcuts.conversation(8) == KeyboardShortcut("9"))
        #expect(MenuBarShortcuts.account(0) == KeyboardShortcut("1", modifiers: [.control, .command]))
        #expect(MenuBarShortcuts.account(8) == KeyboardShortcut("9", modifiers: [.control, .command]))
        for index in [-1, 9, 10] {
            #expect(MenuBarShortcuts.conversation(index) == nil)
            #expect(MenuBarShortcuts.account(index) == nil)
        }
    }
}
