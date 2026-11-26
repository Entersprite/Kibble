import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct DeviceNotificationPauseTests {
    @Test func defaultIsOffAndExplicitPauseResumePersistsForEveryAccount() {
        let store = PauseMemoryStore()
        let model = DeviceNotificationPause(store: store)
        #expect(!model.isActive)
        model.pause(for: .untilResumed)
        #expect(model.isActive)
        #expect(DeviceNotificationPause(store: store).isActive)
        model.resume()
        #expect(!DeviceNotificationPause(store: store).isActive)
    }

    @Test func timedPauseExpiresAtItsBoundaryWithoutBackgroundWork() {
        let store = PauseMemoryStore()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = DeviceNotificationPause(store: store, now: { now })
        model.pause(for: .oneHour)
        now = now.addingTimeInterval(3599)
        #expect(model.isActive)
        now = now.addingTimeInterval(1)
        #expect(!model.isActive)
    }

    @Test func unreadablePauseWithholdsUntilExplicitResumeWithoutOverwritingOnLoad() {
        let store = PauseMemoryStore()
        store.refuseLoad = true
        let model = DeviceNotificationPause(store: store)
        #expect(model.isActive)
        #expect(model.lastError != nil)
        #expect(store.writes == 0)
        model.resume()
        #expect(!model.isActive)
        #expect(store.value == .off)
        #expect(model.lastError == nil)
    }

    @Test func refusedSaveKeepsTheSessionChoiceAndReportsPersistenceFailure() {
        let store = PauseMemoryStore()
        store.refuseSave = true
        let model = DeviceNotificationPause(store: store)
        model.pause(for: .untilResumed)
        #expect(model.isActive)
        #expect(model.lastError != nil)
        #expect(store.value == nil)
        store.refuseSave = false
        model.resume()
        #expect(store.value == .off)
        #expect(model.lastError == nil)
    }
}

@MainActor
private final class PauseMemoryStore: DeviceNotificationPauseStore {
    private struct Refused: Error {}
    var value: Pause?
    var refuseLoad = false
    var refuseSave = false
    var writes = 0
    func load() throws -> Pause? {
        if refuseLoad {
            throw Refused()
        }
        return value
    }

    func save(_ pause: Pause) throws {
        if refuseSave {
            throw Refused()
        }
        value = pause; writes += 1
    }
}
