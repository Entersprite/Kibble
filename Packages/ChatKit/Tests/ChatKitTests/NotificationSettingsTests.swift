import Foundation
import Testing
@testable import ChatKit

struct NotificationSettingsTests {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let dm = Conversation(id: Conversation.ID("dm/1"), kind: .directMessage, hasUnread: true)
    private let meet = Conversation(id: Conversation.ID("space/m"), kind: .meetChat, hasUnread: true)
    private let space = Conversation(id: Conversation.ID("space/s"), kind: .space)

    private var everyShape: NotificationSettings {
        NotificationSettings(records: [
            SettingsRecord(
                scope: .global,
                value: .rule(NotificationRule(delivery: .banner)),
                modifiedAt: at,
                modifiedBy: "mac"
            ),
            SettingsRecord(
                scope: .section(.meetChats),
                value: .rule(NotificationRule()),
                modifiedAt: at,
                modifiedBy: "mac"
            ),
            SettingsRecord(
                scope: .conversation(Conversation.ID("space/s")),
                value: .rule(NotificationRule(readReceipts: false)), modifiedAt: at, modifiedBy: "phone"
            ),
            SettingsRecord(
                scope: .keywords,
                value: .keywords(["release", "outage"]),
                modifiedAt: at,
                modifiedBy: "mac"
            ),
            SettingsRecord(scope: .pause, value: .pause(.until(at)), modifiedAt: at, modifiedBy: "mac")
        ])
    }

    // MARK: - Wire format

    @Test func everySettingsShapeMatchesItsGoldenFile() throws {
        try expectWireStable(everyShape, golden: "notification-settings")
        try expectWireStable(
            NotificationRule(
                delivery: .notificationCenter, showsPreview: false, showsUnread: true,
                countsInBadge: false, readReceipts: true, notifyAbout: .mentions
            ),
            golden: "notification-rule"
        )
        try expectWireStable(NotificationRule(), golden: "notification-rule-empty")
    }

    /// Every token a settings file can spell, in one golden: each `Delivery`,
    /// each `SectionKey`, each `Pause`. A renamed case is then a diff here
    /// rather than an older build silently decoding `.unknown`.
    ///
    /// Three records under the one `.pause` scope is not a state the model
    /// produces - a scope has one record - but this file pins spellings, not
    /// a state.
    @Test func everyTokenMatchesItsGoldenFile() throws {
        func section(_ key: SectionKey, _ rule: NotificationRule) -> SettingsRecord {
            SettingsRecord(scope: .section(key), value: .rule(rule), modifiedAt: at, modifiedBy: "mac")
        }
        func pause(_ pause: Pause) -> SettingsRecord {
            SettingsRecord(scope: .pause, value: .pause(pause), modifiedAt: at, modifiedBy: "mac")
        }
        let settings = NotificationSettings(records: [
            section(.directMessages, NotificationRule(delivery: .off)),
            section(.groupChats, NotificationRule(delivery: .notificationCenter)),
            section(.spaces, NotificationRule(delivery: .banner)),
            section(.apps, NotificationRule(delivery: .bannerAndSound)),
            section(.meetChats, NotificationRule(notifyAbout: .allMessages)),
            section(.other, NotificationRule(notifyAbout: .mentions)),
            pause(.off),
            pause(.until(at)),
            pause(.untilResumed)
        ])
        try expectWireStable(settings, golden: "notification-tokens")
    }

    /// Exhaustive on purpose: a new case stops this compiling until it is
    /// added to `everyTokenMatchesItsGoldenFile` and its golden.
    private func everyTokenIsInTheGolden(
        _ delivery: Delivery, _ section: SectionKey, _ pause: Pause, _ notifyAbout: NotifyAbout
    ) {
        switch delivery {
        case .off, .notificationCenter, .banner, .bannerAndSound, .unknown: break
        }
        switch section {
        case .directMessages, .groupChats, .spaces, .apps, .meetChats, .other, .unknown: break
        }
        switch pause {
        case .off, .until, .untilResumed, .unknown: break
        }
        switch notifyAbout {
        case .allMessages, .mentions, .unknown: break
        }
    }

    @Test func aPauseOfEveryKindRoundTrips() throws {
        for pause in [Pause.off, .untilResumed, .until(at)] {
            let decoded = try Wire.decode(Pause.self, from: Wire.json(pause))
            #expect(decoded == pause)
        }
    }

    /// An older build re-saving the file must not destroy a newer build's record.
    @Test func anUnknownScopeAndValueSurviveARoundTrip() throws {
        let json = #"""
        {"modifiedAt":"2026-09-24T10:00:00Z","modifiedBy":"d","scope":{"type":"workspace","id":"w1"},\#
        "value":{"type":"schedule","days":[1,2]}}
        """#
        let record = try Wire.decode(SettingsRecord.self, from: json)
        guard case let .unknown(scopeType, _) = record.scope,
              case let .unknown(valueType, _) = record.value else {
            Issue.record("expected unknown scope and value, got \(record)")
            return
        }
        #expect(scopeType == "workspace")
        #expect(valueType == "schedule")
        let original = try Wire.decode(JSONValue.self, from: json)
        let reencoded = try Wire.decode(JSONValue.self, from: Wire.json(record))
        guard case let .object(before) = original, case let .object(after) = reencoded else {
            Issue.record("expected objects")
            return
        }
        #expect(after["scope"] == before["scope"])
        #expect(after["value"] == before["value"])
    }

    @Test func anUnknownRuleFieldIsKeptOnReEncode() throws {
        let rule = try Wire.decode(NotificationRule.self, from: #"{"delivery":"banner","sound":"chime"}"#)
        #expect(rule.delivery == .banner)
        #expect(rule.unrecognisedFields["sound"] == .string("chime"))
        #expect(try Wire.json(rule).contains(#""sound":"chime""#))
    }

    @Test func missingFieldsInheritAndAMissingRecordListIsEmpty() throws {
        #expect(try Wire.decode(NotificationRule.self, from: "{}").isEmpty)
        let settings = try Wire.decode(NotificationSettings.self, from: "{}")
        #expect(settings.records.isEmpty)
        #expect(settings.schemaVersion == NotificationSettings.currentSchemaVersion)
    }

    @Test func anUnknownDeliveryTokenDecodesAndResolvesAsInherit() throws {
        let rule = try Wire.decode(NotificationRule.self, from: #"{"delivery":"timeSensitive"}"#)
        #expect(rule.delivery == .unknown("timeSensitive"))
        #expect(NotificationRule.resolve([rule]).delivery == .bannerAndSound)
    }

    /// A build that predates `notifyAbout` keeps it; this one now names it,
    /// so it is no longer an unrecognised field.
    @Test func notifyAboutIsANamedFieldNotAnUnrecognisedOne() throws {
        let json = #"{"notifyAbout":"mentions"}"#
        let rule = try Wire.decode(NotificationRule.self, from: json)
        #expect(rule.notifyAbout == .mentions)
        #expect(rule.unrecognisedFields.isEmpty)
    }

    // MARK: - Records

    /// Clearing never deletes: an emptied record with a newer stamp is what
    /// wins a future merge without tombstones (spec §2.2).
    @Test func settingARuleReplacesItsRecordAndAnEmptyRuleStaysARecord() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .off), for: .section(.spaces), at: at, by: "mac")
        settings.setRule(NotificationRule(), for: .section(.spaces), at: at.addingTimeInterval(60), by: "mac")
        #expect(settings.records.count == 1)
        #expect(settings.rule(for: .section(.spaces))?.isEmpty == true)
        #expect(settings.record(for: .section(.spaces))?.modifiedAt == at.addingTimeInterval(60))
    }

    // MARK: - Resolution for a conversation

    @Test func meetChatsGetThePresetWithNothingSaved() {
        let resolved = NotificationSettings().resolve(for: meet)
        #expect(resolved.delivery == .off)
        #expect(!resolved.showsUnread)
        #expect(!resolved.countsInBadge)
        #expect(resolved.readReceipts)
    }

    @Test func aSectionRecordBeatsThePresetAndAConversationRecordBeatsBoth() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .banner), for: .section(.meetChats), at: at, by: "mac")
        #expect(settings.resolve(for: meet).delivery == .banner)
        settings.setRule(
            NotificationRule(delivery: .notificationCenter),
            for: .conversation(meet.id),
            at: at,
            by: "mac"
        )
        #expect(settings.resolve(for: meet).delivery == .notificationCenter)
    }

    /// Review Focus 5.
    @Test func resettingMeetChatsReturnsToThePresetNotTheGlobalDefault() {
        var settings = NotificationSettings()
        settings.setRule(
            NotificationRule(delivery: .banner, showsUnread: true),
            for: .section(.meetChats),
            at: at,
            by: "mac"
        )
        settings.setRule(NotificationRule(), for: .section(.meetChats), at: at, by: "mac")
        #expect(settings.resolve(for: meet).delivery == .off)
        #expect(!settings.resolve(for: meet).showsUnread)
    }

    @Test func aGlobalRecordReachesEverySectionWithoutItsOwn() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: at, by: "mac")
        #expect(!settings.resolve(for: dm).readReceipts)
        #expect(!settings.resolve(for: meet).readReceipts)
        #expect(!settings.resolvedGlobal.readReceipts)
    }

    @Test func whatASectionInheritsExcludesItsOwnRecord() {
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(delivery: .banner), for: .section(.meetChats), at: at, by: "mac")
        #expect(settings.inherited(bySection: .meetChats).delivery == .off)
        #expect(settings.resolvedSection(.meetChats).delivery == .banner)
        #expect(settings.inherited(bySection: .spaces).delivery == .bannerAndSound)
    }

    @Test func theBadgeCountsUnreadConversationsWhoseRuleCountsThem() {
        // `meet` is unread but the preset excludes it; `space` is read.
        #expect(NotificationSettings().badgeCount(of: [dm, meet, space]) == 1)
    }
}
