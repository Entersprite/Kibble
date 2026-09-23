import AppCore
import AppKit
import SwiftUI

/// The main window's scene id, shared by the shell's `Window` and everything
/// that asks for it to be shown.
public enum MainWindow {
    public static let id = "main"

    /// Brings the main window forward, opening it if it was closed. For a
    /// `Window` scene `openWindow(id:)` reuses the one window rather than
    /// making a second - the reason the shell uses `Window`, not `WindowGroup`.
    @MainActor
    static func show(using openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate()
    }
}

/// The menu-bar icon.
///
/// Also the one view guaranteed to exist while no window does, which makes it
/// where `AppEnvironment.windowRequests` is honoured: a notification clicked
/// with the window closed bumps the counter, and this opens the window.
/// `[Verify]` that a `MenuBarExtra` label receives `onChange` on macOS 26 - the
/// live check; the fallback is an AppKit activate-and-reopen in this package.
public struct MenuBarLabel: View {
    private let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        // Checked with `NSImage(systemSymbolName:)` before use - a wrong
        // symbol name compiles and renders as nothing (`CLAUDE.md`).
        Label("GChat", systemImage: "bubble.left.and.bubble.right")
            .labelStyle(.iconOnly)
            .onChange(of: environment.windowRequests) {
                MainWindow.show(using: openWindow)
            }
    }
}

/// The menu-bar item's menu: a way back to the window, and a way to quit now
/// that closing the window no longer does.
public struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("Open GChat") {
            MainWindow.show(using: openWindow)
        }
        Divider()
        Button("Quit GChat") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
