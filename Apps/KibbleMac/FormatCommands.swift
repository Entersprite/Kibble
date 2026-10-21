import DesignSystem
import SwiftUI

/// The menu bar's Format menu: Bold, Italic, Underline, Strikethrough and
/// Code, with the shortcuts the composer's format button shows. It acts on
/// the composer whose field has the keyboard, which publishes its formatting
/// only then and only where messages can be formatted
/// (`ComposerFormatting`); anywhere else every item is disabled.
struct FormatCommands: Commands {
    @FocusedValue(\.composerFormatting) private var formatting

    var body: some Commands {
        CommandMenu("Format") {
            ForEach(ComposerFormat.menuBarItems) { format in
                Button(format.title) { formatting?.apply(format) }
                    .keyboardShortcut(format.shortcut)
                    .disabled(formatting == nil)
            }
        }
    }
}
