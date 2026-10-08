import AppKit
import Foundation

/// Whether this Mac is in use: awake, displays on, unlocked, and this login
/// session in front (active-presence spec §5). Pure, so every combination is
/// tested; the monitor below only feeds it.
struct DeviceActivityState: Equatable, Sendable {
    enum Signal: Equatable, Sendable {
        case systemSlept, systemWoke, displaysSlept, displaysWoke, locked, unlocked, sessionLeft,
             sessionReturned
    }

    private(set) var systemAsleep = false
    private(set) var displaysAsleep = false
    private(set) var locked = false
    private(set) var sessionAway = false

    /// A dark display counts as away even with the Mac awake: nobody is at it.
    var isInUse: Bool {
        !systemAsleep && !displaysAsleep && !locked && !sessionAway
    }

    mutating func apply(_ signal: Signal) {
        switch signal {
        case .systemSlept: systemAsleep = true
        case .systemWoke: systemAsleep = false
        case .displaysSlept: displaysAsleep = true
        case .displaysWoke: displaysAsleep = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .sessionLeft: sessionAway = true
        case .sessionReturned: sessionAway = false
        }
    }
}

/// Reports `DeviceActivityState.isInUse` as it changes, for
/// `AppEnvironment.setDeviceActive(_:)`. In `MacHost` for the reason
/// `AppActivityMonitor` is: it is AppKit, and `AppCore` is what iOS links.
///
/// In use at launch, so only changes are sent. One fresh stream per access,
/// each with its own observers and state, broadcast like `AppActivityMonitor`'s
/// (`findings.md` §25.10).
///
/// The lock notifications are distributed ones; whether a sandboxed app
/// receives them is `[Verify]` on the owner's first lock.
@MainActor
public final class DeviceActivityMonitor {
    nonisolated static let signals: [Notification.Name: DeviceActivityState.Signal] = [
        NSWorkspace.willSleepNotification: .systemSlept,
        NSWorkspace.didWakeNotification: .systemWoke,
        NSWorkspace.screensDidSleepNotification: .displaysSlept,
        NSWorkspace.screensDidWakeNotification: .displaysWoke,
        NSWorkspace.sessionDidResignActiveNotification: .sessionLeft,
        NSWorkspace.sessionDidBecomeActiveNotification: .sessionReturned,
        screenIsLocked: .locked,
        screenIsUnlocked: .unlocked
    ]

    nonisolated static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    nonisolated static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private let workspace: NotificationCenter
    private let distributed: NotificationCenter

    public convenience init() {
        self.init(
            workspace: NSWorkspace.shared.notificationCenter,
            distributed: DistributedNotificationCenter.default()
        )
    }

    /// Centers injected for tests, which post to plain ones.
    init(workspace: NotificationCenter, distributed: NotificationCenter) {
        self.workspace = workspace
        self.distributed = distributed
    }

    public var changes: AsyncStream<Bool> {
        let workspace = workspace
        let distributed = distributed
        return AsyncStream { continuation in
            let state = StateBox()
            let tokens = Self.signals.map { name, signal in
                let center = name == Self.screenIsLocked || name == Self
                    .screenIsUnlocked ? distributed : workspace
                let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        if let inUse = state.apply(signal) {
                            continuation.yield(inUse)
                        }
                    }
                }
                return (center, token)
            }
            let observers = Observers(tokens)
            continuation.onTermination = { _ in observers.removeAll() }
        }
    }
}

/// One stream's state, touched only on the main queue its observers use.
@MainActor
private final class StateBox {
    private var state = DeviceActivityState()

    /// The new answer, or `nil` when this signal did not change it.
    func apply(_ signal: DeviceActivityState.Signal) -> Bool? {
        let before = state.isInUse
        state.apply(signal)
        return state.isInUse == before ? nil : state.isInUse
    }
}

/// The observer tokens, solely so `onTermination` can remove them: the tokens
/// are opaque and never mutated, as `AppActivityMonitor`'s `ObserverTokens`.
private final class Observers: @unchecked Sendable {
    private let entries: [(NotificationCenter, NSObjectProtocol)]

    init(_ entries: [(NotificationCenter, NSObjectProtocol)]) {
        self.entries = entries
    }

    func removeAll() {
        for (center, token) in entries {
            center.removeObserver(token)
        }
    }
}
