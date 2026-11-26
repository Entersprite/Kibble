import ChatKit
import DesignSystem
import Foundation
import Observation

@MainActor
public protocol DeviceNotificationPauseStore {
    func load() throws -> Pause?
    func save(_ pause: Pause) throws
}

/// A device preference shared by every account. It owns no timer or provider.
@MainActor
@Observable
public final class DeviceNotificationPause {
    public private(set) var pause: Pause
    public private(set) var lastError: String?
    @ObservationIgnored private let store: any DeviceNotificationPauseStore
    @ObservationIgnored private let now: () -> Date

    public init(store: any DeviceNotificationPauseStore, now: @escaping () -> Date = { Date() }) {
        self.store = store; self.now = now
        do {
            pause = try store.load() ?? .off
        } catch {
            pause = .untilResumed
            lastError = "Kibble couldn’t read the device notification pause. " +
                "Notifications are paused until you resume."
        }
    }

    public var isActive: Bool {
        pause.isActive(at: now())
    }

    public var status: String? {
        Display.pauseStatus(pause, now: now())
    }

    public func pause(for duration: PauseDuration, calendar: Calendar = .current) {
        set(duration.pause(from: now(), calendar: calendar))
    }

    public func resume() {
        set(.off)
    }

    private func set(_ pause: Pause) {
        self.pause = pause
        do {
            try store.save(pause)
            lastError = nil
        } catch {
            lastError = "Kibble couldn’t save the device notification pause."
        }
    }
}
