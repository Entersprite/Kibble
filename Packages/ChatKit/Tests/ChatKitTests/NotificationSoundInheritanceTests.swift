import Foundation
import Testing
@testable import ChatKit

struct NotificationSoundInheritanceTests {
    private let custom = NotificationSound(id: "E72E2B30-3C45-4683-9F54-BB17859ACDEB", name: "Soft Chime")
    private let conversation = Conversation(id: .init("chat"), kind: .space)

    @Test func sharedDefaultsApplyOnlyToFieldsWithoutASpecificChoice() {
        var settings = NotificationSettings(sharedDefaults: .init(
            delivery: .banner, sound: .system, showsPreview: false, readReceipts: false
        ))
        settings.setRule(
            .init(sound: custom, countsInBadge: false),
            for: .conversation(conversation.id),
            at: .distantPast,
            by: "device"
        )
        settings.setRule(.init(showsPreview: true), for: .section(.spaces), at: .distantPast, by: "device")
        let before = settings.resolve(for: conversation)
        #expect(before.sound == custom)
        #expect(before.showsPreview)
        #expect(!before.readReceipts)
        settings.sharedDefaults = .init(sound: .kibble, showsPreview: false, readReceipts: true)
        let after = settings.resolve(for: conversation)
        #expect(after.sound == custom)
        #expect(after.showsPreview)
        #expect(!after.countsInBadge)
        #expect(after.readReceipts)
    }

    @Test func accountSoundBeatsSharedDefaultAndResetReturnsToInheritance() {
        var settings = NotificationSettings(sharedDefaults: .init(sound: custom))
        settings.setRule(.init(sound: .system), for: .global, at: .distantPast, by: "device")
        #expect(settings.resolvedGlobal.sound == .system)
        settings.setRule(.init(), for: .global, at: .distantPast, by: "device")
        #expect(settings.resolve(for: conversation).sound == custom)
        #expect(!NotificationRule(sound: custom).isEmpty)
    }

    @Test func newFieldsRoundTripAndOldDocumentsKeepTheirDefaults() throws {
        var settings = NotificationSettings(sharedDefaults: .init(sound: custom, sharesTyping: true))
        settings.setRule(.init(sound: .system), for: .section(.spaces), at: .distantPast, by: "device")
        let bytes = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: bytes) == settings)
        let old = try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8))
        #expect(old.sharedDefaults == nil)
        #expect(old.resolvedGlobal.sound == .kibble)
    }
}
