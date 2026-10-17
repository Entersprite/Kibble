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
    /// Settings › Updates and the updater behind it, for the life of the
    /// process like everything else here. No updater in a development build
    /// (`KibbleUpdatesEnabled`), so a dev build never replaces itself.
    public let updates: UpdateSettingsModel
    public let diagnostics: DiagnosticReportStore
    let callDiagnostics: AudioCallDiagnosticExporter
    public let callSignIn: CallSignInRecovery
    let callVideo: CallVideoController
    let callAudioDevices: CallAudioDeviceController
    let notifications: UserNotificationDelivery
    private var activityTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var windowObservers: [NSObjectProtocol] = []
    var callAlerts: IncomingCallAlerts?
    var callResponseTask: Task<Void, Never>?
    var callWindowHost: AudioCallWindowHost?
    var terminationRequested = false
    /// Filters the minimise observers to the main window, which the shell's
    /// `reportsMainWindow(to:)` names.
    let mainWindowMinimising: MainWindowMinimising

    override public init() {
        let notifications = UserNotificationDelivery()
        self.notifications = notifications
        // Beside the database. If the container cannot be reached, settings
        // still work for the session and are simply not kept.
        let settingsStore: any NotificationSettingsStore =
            (try? SystemLaunchServices.supportDirectory()).map(FileNotificationSettingsStore.init(directory:))
                ?? InMemoryNotificationSettingsStore()
        let services = SystemLaunchServices(arguments: .fromCommandLine())
        callAudioDevices = services.callAudioDevices
        callVideo = services.callVideo
        callSignIn = services.callSignIn
        callDiagnostics = services.callDiagnostics
        let diagnostics = DiagnosticReportStore(directory: try? SystemLaunchServices.supportDirectory())
        services.diagnostics = diagnostics
        let environment = AppEnvironment(
            services: services,
            notifications: notifications,
            settingsStore: settingsStore
        )
        self.environment = environment
        mainWindowMinimising = MainWindowMinimising { environment.setWindowMinimized($0) }
        let info = Bundle.main.infoDictionary ?? [:]
        updates = UpdateSettingsModel(
            updater: UpdateSettingsModel
                .isEnabled(infoValue: info["KibbleUpdatesEnabled"]) ? SparkleUpdater() : nil,
            defaults: .standard,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        self.diagnostics = diagnostics
        super.init()
    }

    public func applicationWillFinishLaunching(_: Notification) {
        // Before launch completes, or the click that launched the app is lost.
        notifications.install()
    }

    public func applicationDidFinishLaunching(_: Notification) {
        startCallWindowObservation()
        diagnostics.start()
        diagnostics.sampleMemory()
        memoryTask = Task { [diagnostics] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                diagnostics.sampleMemory()
            }
        }
        let environment = environment
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak environment] in
            MainActor.assumeIsolated { environment?.releasePresentationCaches() }
        }
        memoryPressureSource = pressure
        pressure.activate()
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

        // Green while this Mac is in use (active-presence spec §5). In use at
        // launch, which `AppEnvironment` already assumes, so only changes go.
        let deviceChanges = DeviceActivityMonitor().changes
        deviceTask = Task {
            for await inUse in deviceChanges {
                environment.setDeviceActive(inUse)
            }
        }

        // A minimised window's views do not disappear, so `.onDisappear`
        // cannot report it. `[Verify]` on macOS 26 - the shell's live check.
        // Every window posts these; `MainWindowMinimising` keeps the main one's.
        let center = NotificationCenter.default
        let minimising = mainWindowMinimising
        windowObservers = [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated { minimising.handle(name, object: window) }
                }
            }

        updates.start()
    }

    /// Closing the window must not quit: notifications only arrive while the
    /// app runs. Stated explicitly rather than trusting SwiftUI's default,
    /// which Apple does not document and which differs between `Window` and
    /// `WindowGroup`. Cmd-Q and the menu-bar item's Quit still quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
