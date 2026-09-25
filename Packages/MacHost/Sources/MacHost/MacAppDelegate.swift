import AppCore
import AppKit
import Foundation

/// Owns the session for the life of the process, not the life of a window.
///
/// **Why the environment moved here.** It used to be `@State` on the app
/// struct and was started, and told about focus, from `.task`s on the window's
/// own view. Closing the window cancelled those tasks: the frontmost reports
/// stopped, `isActive` froze at whatever it last was, and automatic mark-read
/// could go on publishing receipts for a conversation nobody could see. A
/// menu-bar app makes "running with no window" the normal state, so everything
/// the session depends on now starts here, once, whether a window ever opens
/// or not.
@MainActor
public final class MacAppDelegate: NSObject, NSApplicationDelegate {
    public let environment: AppEnvironment
    private let notifications: UserNotificationDelivery
    private var activityTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []

    override public init() {
        let notifications = UserNotificationDelivery()
        self.notifications = notifications
        // Beside the database. If the container cannot be reached, settings
        // still work for the session and are simply not kept.
        let settingsStore: any NotificationSettingsStore =
            (try? SystemLaunchServices.supportDirectory()).map(FileNotificationSettingsStore.init(directory:))
                ?? InMemoryNotificationSettingsStore()
        environment = AppEnvironment(
            services: SystemLaunchServices(arguments: .fromCommandLine()),
            notifications: notifications,
            settingsStore: settingsStore
        )
        super.init()
    }

    public func applicationWillFinishLaunching(_: Notification) {
        // Before launch completes, or the click that launched the app is lost.
        notifications.install()
    }

    public func applicationDidFinishLaunching(_: Notification) {
        let environment = environment
        Task { await environment.start() }

        // Read once so a launch that is already frontmost says so; every
        // later value is a real transition (`AppActivityMonitor`'s doc).
        let monitor = AppActivityMonitor()
        environment.setActive(monitor.isActive)
        let changes = monitor.changes
        activityTask = Task {
            for await active in changes {
                environment.setActive(active)
            }
        }

        // A minimised window's views do not disappear, so `.onDisappear`
        // cannot report it. `[Verify]` on macOS 26 - the shell's live check.
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { environment.setWindowMinimized(true) } },
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { environment.setWindowMinimized(false) } }
        ]
    }

    /// Closing the window must not quit: notifications only arrive while the
    /// app runs. Stated explicitly rather than trusting SwiftUI's default,
    /// which Apple does not document and which differs between `Window` and
    /// `WindowGroup`. Cmd-Q and the menu-bar item's Quit still quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
