import AppCore
import AppKit
import ChatKit
import DesignSystem
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
        Group {
            if environment.badgeCount > 0 {
                Label("\(environment.badgeCount)", systemImage: "bubble.left.and.bubble.right")
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Kibble", systemImage: "bubble.left.and.bubble.right")
                    .labelStyle(.iconOnly)
            }
        }
        .onChange(of: environment.windowRequests) {
            MainWindow.show(using: openWindow)
        }
        .onChange(of: environment.badgeCount, initial: true) { _, count in
            DockBadge.show(count)
        }
    }
}

/// The menu-bar item's menu: Pause, a way back to the window, and a way to
/// quit now that closing the window no longer does.
public struct MenuBarContent: View {
    private let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        if environment.canEditNotificationRules {
            if let status = environment.pauseStatus {
                Text(status)
                Button("Resume Notifications") { environment.resumeNotifications() }
            } else {
                Menu("Pause Notifications") {
                    ForEach(PauseDuration.allCases, id: \.self) { duration in
                        Button(Display.title(of: duration)) { environment.pauseNotifications(duration) }
                    }
                }
            }
            Divider()
        }
        Button("Open Kibble") {
            MainWindow.show(using: openWindow)
        }
        Divider()
        Button("Quit Kibble") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
