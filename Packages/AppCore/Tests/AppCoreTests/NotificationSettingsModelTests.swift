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
        defaults: UserDefaults = UserDefaults(suiteName: "NotificationSettingsModelTests-\(UUID())")!
    ) -> NotificationSettingsModel {
        NotificationSettingsModel(store: store, defaults: defaults, now: { [at] in at })
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

    /// Review Focus 1: an unreadable file starts from defaults, says so, and
    /// edits still work.
    @Test func anUnreadableFileFallsBackToDefaultsAndSaysSo() {
        let settings = model(ThrowingStore())
        settings.switchAccount(to: alice)
        #expect(settings.settings.records.isEmpty)
        #expect(settings.lastError != nil)
        settings.update(NotificationRule(delivery: .off), for: .global)
        #expect(settings.rule(for: .global).delivery == .off)
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
}

/// A reference box: an escaping main-actor closure may not mutate a captured
/// local `var` under Swift 6.
@MainActor
private final class Heard {
    var values: [NotificationSettings?] = []
}

private struct ThrowingStore: NotificationSettingsStore {
    struct Unreadable: Error {}
    func load(for _: Member.ID) throws -> NotificationSettings? {
        throw Unreadable()
    }

    func save(_: NotificationSettings, for _: Member.ID) {}
    func deviceID() -> String {
        "dev"
    }
}
