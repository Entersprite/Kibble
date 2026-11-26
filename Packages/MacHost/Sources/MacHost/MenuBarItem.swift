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
    private let aggregateBadgeCount: Int?
    private let accountWindowRequests: Int
    private var badgeTotal: Int {
        aggregateBadgeCount ?? environment.badgeCount
    }

    @Environment(\.openWindow) private var openWindow

    public init(
        environment: AppEnvironment,
        aggregateBadgeCount: Int? = nil,
        accountWindowRequests: Int = 0
    ) {
        self.environment = environment
        self.aggregateBadgeCount = aggregateBadgeCount
        self.accountWindowRequests = accountWindowRequests
    }

    public var body: some View {
        // Checked with `NSImage(systemSymbolName:)` before use - a wrong
        // symbol name compiles and renders as nothing (`CLAUDE.md`).
        Group {
            if badgeTotal > 0 {
                Label("\(badgeTotal)", systemImage: "bubble.left.and.bubble.right")
                    .labelStyle(.titleAndIcon)
                    // A bare number says nothing to VoiceOver about whose it is.
                    .accessibilityLabel(MenuBarLabel.spokenLabel(unread: badgeTotal))
            } else {
                Label("Kibble", systemImage: "bubble.left.and.bubble.right")
                    .labelStyle(.iconOnly)
            }
        }
        .onChange(of: environment.windowRequests) {
            MainWindow.show(using: openWindow)
        }
        .onChange(of: accountWindowRequests, initial: true) { _, count in
            if count > 0 {
                MainWindow.show(using: openWindow)
            }
        }
        .onChange(of: badgeTotal, initial: true) { _, count in
            DockBadge.show(count)
        }
    }

    /// What VoiceOver reads for the item: "Kibble, 3 unread" while there is
    /// something unread, and the label's own "Kibble" otherwise.
    static func spokenLabel(unread: Int) -> String {
        unread > 0 ? "Kibble, \(unread) unread" : "Kibble"
    }
}

/// The menu-bar item's menu: Pause, a way back to the window, and a way to
/// quit now that closing the window no longer does.
public struct MenuBarContent: View {
    private let environment: AppEnvironment
    private let devicePause: DeviceNotificationPause?
    @Environment(\.openWindow) private var openWindow

    public init(environment: AppEnvironment, devicePause: DeviceNotificationPause? = nil) {
        self.environment = environment
        self.devicePause = devicePause
    }

    public var body: some View {
        if environment.canEditNotificationRules || devicePause != nil {
            if let status = devicePause?.status ?? environment.pauseStatus {
                Text(status)
                Button("Resume Notifications", systemImage: MenuBarSymbols.resumeNotifications) {
                    if let devicePause {
                        devicePause.resume()
                    } else {
                        environment.resumeNotifications()
                    }
                }
            } else {
                Menu("Pause Notifications", systemImage: MenuBarSymbols.pauseNotifications) {
                    ForEach(PauseDuration.allCases, id: \.self) { duration in
                        Button(Display.title(of: duration)) {
                            if let devicePause {
                                devicePause.pause(for: duration)
                            } else {
                                environment.pauseNotifications(duration)
                            }
                        }
                    }
                }
            }
            Divider()
        }
        Button("Open Kibble", systemImage: MenuBarSymbols.openWindow) {
            MainWindow.show(using: openWindow)
        }
        Divider()
        Button("Quit Kibble") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
