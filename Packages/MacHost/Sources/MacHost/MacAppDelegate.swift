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
    private let legacyEnvironment: AppEnvironment
    public let accountHost: SystemAccountHost?
    public var environment: AppEnvironment {
        accountHost?.workspace?.selectedEnvironment ?? legacyEnvironment
    }

    /// Settings › Updates and the updater behind it, for the life of the
    /// process like everything else here. No updater in a development build
    /// (`KibbleUpdatesEnabled`), so a dev build never replaces itself.
    public let updates: UpdateSettingsModel
    /// Settings › Calls: the incoming call panel, its ring and Focus access.
    public let callSettings: CallSettingsModel
    let callPanel = IncomingCallPanelHost()
    let callRinger: CallRinger
    let callSounds = CallSoundFeedback()
    public let diagnostics: DiagnosticReportStore
    private let legacyCallDiagnostics: AudioCallDiagnosticExporter
    var callDiagnostics: AudioCallDiagnosticExporter {
        selectedCallBinding?.diagnostics ?? legacyCallDiagnostics
    }

    private let legacyCallSignIn: CallSignInRecovery
    public var callSignIn: CallSignInRecovery {
        selectedCallBinding?.signIn ?? legacyCallSignIn
    }

    private let legacyCallVideo: CallVideoController
    var callVideo: CallVideoController {
        selectedCallBinding?.video ?? legacyCallVideo
    }

    let callCamera = CallCameraRequest()
    /// The menu bar's Call menu, following whichever account's call holds the
    /// device (`CallMenuModel`).
    public let callMenu = CallMenuModel()
    private let legacyCallAudioDevices: CallAudioDeviceController
    var callAudioDevices: CallAudioDeviceController {
        selectedCallBinding?.audioDevices ?? legacyCallAudioDevices
    }

    var accountCalls: NativeAccountCallCoordinator?
    private var selectedCallBinding: NativeAccountCallBinding? {
        guard let host = accountHost, let workspace = host.workspace,
              let account = workspace.accounts.first(where: { $0.id == workspace.selectedID })
        else { return nil }
        return host.callBindings.binding(for: account)
    }

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
        let fixture = Self.makeAccountHost(notifications: notifications)
        accountHost = fixture
        let services =
            SystemLaunchServices(arguments: fixture == nil ? .fromCommandLine() :
                LaunchArguments(backend: .fixture))
        legacyCallAudioDevices = services.callAudioDevices
        legacyCallVideo = services.callVideo
        legacyCallSignIn = services.callSignIn
        legacyCallDiagnostics = services.callDiagnostics
        let diagnostics = DiagnosticReportStore(directory: try? SystemLaunchServices.supportDirectory())
        services.diagnostics = diagnostics
        fixture?.diagnostics = diagnostics
        let environment = AppEnvironment(
            services: services,
            notifications: fixture == nil ? notifications : nil,
            settingsStore: settingsStore
        )
        legacyEnvironment = environment
        mainWindowMinimising = MainWindowMinimising {
            if let fixture {
                fixture.setViewing(minimized: $0)
            } else {
                environment.setWindowMinimized($0)
            }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        updates = UpdateSettingsModel(
            updater: UpdateSettingsModel
                .isEnabled(infoValue: info["KibbleUpdatesEnabled"]) ? SparkleUpdater() : nil,
            defaults: .standard,
            version: info["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        self.diagnostics = diagnostics
        let callSettings = CallSettingsModel(
            defaults: .standard,
            ringtoneDirectory: try? SystemLaunchServices.supportDirectory()
                .appendingPathComponent("Ringtones", isDirectory: true)
        )
        self.callSettings = callSettings
        callRinger = CallRinger { callSettings.ringtoneURL }
        super.init()
        callSettings.previewRingtone = { [weak callRinger] in callRinger?.preview($0) }
    }

    private static func makeAccountHost(notifications: UserNotificationDelivery) -> SystemAccountHost? {
        #if DEBUG
            if CommandLine.arguments.contains("--multi-account-fixture") {
                return SystemAccountHost()
            }
        #endif
        let arguments = LaunchArguments.fromCommandLine()
        guard arguments.backend == .local,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--probe=") }) else { return nil }
        return SystemAccountHost(notifications: notifications, usesGoogleAccounts: true)
    }

    public func applicationWillFinishLaunching(_: Notification) {
        // Before launch completes, or the click that launched the app is lost.
        if accountHost == nil || accountHost?.usesGoogleAccounts == true {
            notifications.install()
        }
    }

    public func applicationDidFinishLaunching(_: Notification) {
        if accountHost == nil {
            startCallWindowObservation()
        }
        if accountHost?.usesGoogleAccounts != false {
            diagnostics.start()
            diagnostics.sampleMemory()
        }
        startAccountCalls()
        callMenu.start { [weak self] in self?.callMenuSources() ?? ([], nil) }
        startMemoryMonitoring()
        let environment = legacyEnvironment
        let fixture = accountHost
        Task {
            if let fixture {
                await fixture.start()
            } else {
                await environment.start()
            }
        }

        // Read once so a launch that is already frontmost says so; every
        // later value is a real transition (`AppActivityMonitor`'s doc).
        let monitor = AppActivityMonitor()
        if let fixture {
            fixture.setViewing(active: monitor.isActive)
        } else {
            environment.setActive(monitor.isActive)
        }
        let changes = monitor.changes
        activityTask = Task {
            for await active in changes {
                if let fixture {
                    fixture.setViewing(active: active)
                } else {
                    environment.setActive(active)
                }
            }
        }

        // Green while this Mac is in use (active-presence spec §5). In use at
        // launch, which `AppEnvironment` already assumes, so only changes go.
        let deviceChanges = DeviceActivityMonitor().changes
        deviceTask = Task {
            for await inUse in deviceChanges {
                if let fixture {
                    fixture.setDeviceActive(inUse)
                } else {
                    environment.setDeviceActive(inUse)
                }
            }
        }

        // A minimised window's views do not disappear, so `.onDisappear`
        // cannot report it. `[Verify]` on macOS 26 - the shell's live check.
        // Every window posts these; `MainWindowMinimising` keeps the main one's.
        startWindowMonitoring()

        if accountHost?.usesGoogleAccounts != false {
            updates.start()
        }
    }

    private func startAccountCalls() {
        if let host = accountHost, host.usesGoogleAccounts {
            accountCalls = NativeAccountCallCoordinator(
                host: host, settings: callSettings, notifications: notifications
            )
        }
    }

    private func startWindowMonitoring() {
        let center = NotificationCenter.default
        let minimising = mainWindowMinimising
        windowObservers = [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated { minimising.handle(name, object: window) }
                }
            }
    }

    private func startMemoryMonitoring() {
        if accountHost?.usesGoogleAccounts != false {
            memoryTask = Task { [diagnostics] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    diagnostics.sampleMemory()
                }
            }
        }
        let environment = legacyEnvironment
        let fixture = accountHost
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak environment] in
            MainActor.assumeIsolated {
                if let fixture {
                    fixture.workspace?.releasePresentationCaches()
                } else {
                    environment?.releasePresentationCaches()
                }
            }
        }
        memoryPressureSource = pressure
        pressure.activate()
    }

    public func setMainWindowOpen(_ open: Bool) {
        if let accountHost {
            accountHost.setViewing(open: open)
        } else {
            legacyEnvironment.setWindowOpen(open)
        }
    }

    /// Closing the window must not quit: notifications only arrive while the
    /// app runs. Stated explicitly rather than trusting SwiftUI's default,
    /// which Apple does not document and which differs between `Window` and
    /// `WindowGroup`. Cmd-Q and the menu-bar item's Quit still quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
