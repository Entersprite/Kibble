import AppKit
import Foundation

/// AppKit's half of attaching a file: the open panel behind the composer's
/// paperclip. Its own file, so `SystemLaunchServices` stays free of AppKit.
@MainActor
enum SystemFilePicker {
    /// Files only, several at once. A file chosen here is readable for the
    /// rest of this launch under the sandbox's user-selected rule, which is
    /// as long as a staged file needs.
    static func chooseFilesToSend() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose files to send"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
