import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
struct NotificationSettingsModelTests {
    private let alice = Member.ID("users/alice")
    private let bob = Member.ID("users/bob")
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func model(
        _ store: any NotificationSettingsStore = InMemoryNotificationSettingsStore(deviceID: "dev-1"),
        defaults: UserDefaults = UserDefaults(suiteName: "NotificationSettingsModelTests-\(UUID())")!,
        clock: TestClock? = nil
    ) -> NotificationSettingsModel {
        let clock = clock ?? TestClock(at)
        return NotificationSettingsModel(store: store, defaults: defaults, now: { clock.now })
    }

    @Test func switchingToAnAccountLoadsItsSavedSettings() {
        var saved = NotificationSettings()
        saved.setRule(NotificationRule(delivery: .banner), for: .global, at: at, by: "other")
        let settings = model(InMemoryNotificationSettingsStore([alice: saved]))
        settings.switchAccount(to: alice)
        #expect(settings.rule(for: .global).delivery == .banner)
    }

    @Test func anEditIsStampedAndSaved() {
        let store = InMemoryNotificationSettingsStore(deviceID: "dev-1")
        let settings = model(store)
        settings.switchAccount(to: alice)
        settings.update(NotificationRule(delivery: .off), for: .section(.spaces))
        let record = store.saved(for: alice)?.record(for: .section(.spaces))
        #expect(record?.modifiedAt == at)
        #expect(record?.modifiedBy == "dev-1")
    }

    @Test func resetEmptiesTheRecordRatherThanDeletingIt() {
        let store = InMemoryNotificationSettingsStore()
        let settings = model(store)
        settings.switchAccount(to: alice)
        settings.update(NotificationRule(delivery: .off), for: .section(.spaces))
        settings.reset(.section(.spaces))
        #expect(store.saved(for: alice)?.record(for: .section(.spaces)) != nil)
        #expect(settings.rule(for: .section(.spaces)).isEmpty)
    }

    /// The owner's correction to the spec: sign-out must not forget anything.
    @Test func signingOutAndBackInToTheSameAccountRestoresEverything() {
        let settings = model()
        settings.switchAccount(to: alice)
        settings.update(NotificationRule(readReceipts: false), for: .conversation(Conversation.ID("dm/1")))
        settings.switchAccount(to: nil)
        #expect(settings.rule(for: .conversation(Conversation.ID("dm/1"))).isEmpty)
        settings.switchAccount(to: alice)
        #expect(settings.rule(for: .conversation(Conversation.ID("dm/1"))).readReceipts == false)
    }

    @Test func anotherAccountGetsItsOwnSettings() {
        let settings = model()
        settings.switchAccount(to: alice)
        settings.update(NotificationRule(delivery: .off), for: .global)
        settings.switchAccount(to: bob)
        #expect(settings.rule(for: .global).isEmpty)
        settings.switchAccount(to: alice)
        #expect(settings.rule(for: .global).delivery == .off)
    }

    @Test func editsWithNoAccountAreIgnored() {
        let store = InMemoryNotificationSettingsStore()
        let settings = model(store)
        settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(settings.settings.records.isEmpty)
    }

    @Test func theLegacyGhostModeKeyMovesToTheFirstAccountOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: "ghost-\(UUID())"))
        defaults.set(true, forKey: NotificationSettingsModel.legacyGhostModeKey)
        let settings = model(defaults: defaults)
        settings.switchAccount(to: alice)
        #expect(settings.rule(for: .global).readReceipts == false)
        #expect(!defaults.bool(forKey: NotificationSettingsModel.legacyGhostModeKey))
        settings.switchAccount(to: bob)
        #expect(settings.rule(for: .global).isEmpty)
    }

    /// A fixture launch must not consume the key: its demo account would take
    /// the rule, and the real account would then publish receipts.
    @Test func withMigrationDisabledTheLegacyKeyStaysAndNoRuleIsWritten() throws {
        let defaults = try #require(UserDefaults(suiteName: "ghost-\(UUID())"))
        defaults.set(true, forKey: NotificationSettingsModel.legacyGhostModeKey)
        let store = InMemoryNotificationSettingsStore()
        let settings = NotificationSettingsModel(
            store: store, defaults: defaults, now: { [at] in at }, migratesLegacyGhostMode: false
        )
        settings.switchAccount(to: alice)
        #expect(defaults.bool(forKey: NotificationSettingsModel.legacyGhostModeKey))
        #expect(settings.settings.rule(for: .global) == nil)
        #expect(store.saved(for: alice) == nil)
    }

    /// Review Focus 1: an unreadable file starts from defaults, says so, and
    /// edits still work. Defaults except read receipts, which are off - the
    /// owner's decision (session 26): an unreadable file must not turn on
    /// receipts a saved rule may have turned off.
    @Test func anUnreadableFileFallsBackToDefaultsWithReceiptsOffAndSaysSo() {
        let settings = model(ThrowingStore())
        let heard = Heard()
        settings.onChange = { heard.values.append($0) }
        settings.switchAccount(to: alice)
        #expect(settings.rule(for: .global) == NotificationRule(readReceipts: false))
        #expect(!settings.resolved(for: Conversation(id: Conversation.ID("dm/1"), kind: .directMessage))
            .readReceipts)
        #expect(heard.values.last??.rule(for: .global)?.readReceipts == false)
        #expect(settings.lastError != nil)
        settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(settings.rule(for: .global).delivery == .off)
    }

    /// Saved, not only held: the unreadable file has been moved aside, so the
    /// next launch loads cleanly and would publish receipts again if the
    /// record lived in memory only.
    @Test func theReceiptsOffRecordIsSavedSoTheNextLaunchKeepsIt() {
        let store = ThrowingStore()
        let settings = model(store)
        settings.switchAccount(to: alice)
        #expect(store.saved[alice]?.rule(for: .global)?.readReceipts == false)
    }

    /// The only notice that the defaults are in use must survive the first
    /// edit - which, on a corrupt file, saves successfully.
    @Test func aSuccessfulSaveKeepsTheLoadErrorUntilTheAccountChanges() {
        let settings = model(ThrowingStore())
        settings.switchAccount(to: alice)
        let loadError = settings.lastError
        #expect(loadError != nil)
        settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(settings.lastError == loadError)
        settings.switchAccount(to: nil)
        #expect(settings.lastError == nil)
    }

    /// A save failure is cleared by the next save that works.
    @Test func aSuccessfulSaveClearsAPreviousSaveError() {
        let store = FlakyStore()
        let settings = model(store)
        settings.switchAccount(to: alice)
        store.failsSaves = true
        settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(settings.lastError != nil)
        store.failsSaves = false
        settings.update(NotificationRule(delivery: .banner), for: .global)
        #expect(settings.lastError == nil)
    }

    @Test func listenersHearNilWithoutAnAccountAndTheSettingsWithOne() {
        let settings = model()
        let heard = Heard()
        settings.onChange = { heard.values.append($0) }
        settings.switchAccount(to: alice)
        settings.update(NotificationRule(delivery: .off), for: .global)
        settings.switchAccount(to: nil)
        #expect(heard.values.count == 3)
        #expect(heard.values.last == .some(nil))
        #expect(heard.values[1]?.rule(for: .global)?.delivery == .off)
    }

    @Test func muteAndUnmuteAreSavedAndReportedAsMuted() {
        let store = InMemoryNotificationSettingsStore(deviceID: "dev-1")
        let settings = model(store)
        let dm = Conversation.ID("dm/1")
        settings.switchAccount(to: alice)
        settings.mute(dm)
        #expect(settings.isMuted(dm))
        #expect(store.saved(for: alice)?.isMuted(dm) == true)
        settings.unmute(dm)
        #expect(!settings.isMuted(dm))
        #expect(store.saved(for: alice)?.rule(for: .conversation(dm))?.isEmpty == true)
    }

    /// Review Focus 3: no timer - the pause is over the moment the clock
    /// passes it.
    @Test func aPauseForAnHourIsOverAnHourLater() {
        let clock = TestClock(at)
        let settings = model(clock: clock)
        settings.switchAccount(to: alice)
        settings.pause(for: .oneHour)
        #expect(settings.isPaused)
        clock.now = Date(timeIntervalSince1970: 1_790_003_600)
        #expect(!settings.isPaused)
    }

    @Test func resumingEndsAPauseAndIsSaved() {
        let store = InMemoryNotificationSettingsStore(deviceID: "dev-1")
        let settings = model(store)
        settings.switchAccount(to: alice)
        settings.pause(for: .untilResumed)
        #expect(store.saved(for: alice)?.pause == .untilResumed)
        settings.resume()
        #expect(!settings.isPaused)
        #expect(store.saved(for: alice)?.pause == .off)
    }

    @Test func muteAndPauseWithNoAccountAreIgnored() {
        let settings = model()
        settings.mute(Conversation.ID("dm/1"))
        settings.pause(for: .untilResumed)
        #expect(settings.settings.records.isEmpty)
    }
}

/// A reference box: an escaping main-actor closure may not mutate a captured
/// local `var` under Swift 6.
@MainActor
private final class Heard {
    var values: [NotificationSettings?] = []
}

/// A settable clock: an escaping main-actor closure may not mutate a
/// captured local `var` under Swift 6.
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) {
        self.now = now
    }
}

/// Saves fail while `failsSaves` is set; loads find nothing.
private final class FlakyStore: NotificationSettingsStore, @unchecked Sendable {
    struct Unwritable: Error {}
    var failsSaves = false

    func load(for _: Member.ID) -> NotificationSettings? {
        nil
    }

    func save(_: NotificationSettings, for _: Member.ID) throws {
        if failsSaves {
            throw Unwritable()
        }
    }

    func deviceID() -> String {
        "dev"
    }
}

/// Every load fails; saves are kept for a test to read.
private final class ThrowingStore: NotificationSettingsStore, @unchecked Sendable {
    struct Unreadable: Error {}
    private(set) var saved: [Member.ID: NotificationSettings] = [:]

    func load(for _: Member.ID) throws -> NotificationSettings? {
        throw Unreadable()
    }

    func save(_ settings: NotificationSettings, for account: Member.ID) {
        saved[account] = settings
    }

    func deviceID() -> String {
        "dev"
    }
}
