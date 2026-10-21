import DesignSystem
import SwiftUI

/// The menu bar's Format menu: Bold, Italic, Underline, Strikethrough and
/// Code, with the shortcuts the composer's format button shows. It acts on
/// the composer whose field has the keyboard, which publishes its formatting
/// only then and only where messages can be formatted
/// (`ComposerFormatting`); anywhere else every item is disabled.
///
/// Each item is checked while its style is on at the caret or over the whole
/// selection, as in Notes. A toggle keeps its shortcut, and its menu item
/// shows the value from when the menu opens (measured on macOS 27 in a
/// windowless probe of a `CommandMenu`).
struct FormatCommands: Commands {
    @FocusedValue(\.composerFormatting) private var formatting

    var body: some Commands {
        CommandMenu("Format") {
            ForEach(ComposerFormat.menuBarItems) { format in
                Toggle(format.title, isOn: Binding(
                    get: { formatting?.active.contains(format) ?? false },
                    set: { _ in formatting?.apply(format) }
                ))
                .keyboardShortcut(format.shortcut)
                .disabled(formatting == nil)
            }
        }
    }
}
