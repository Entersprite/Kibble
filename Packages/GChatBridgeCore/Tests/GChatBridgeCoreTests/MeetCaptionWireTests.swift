import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCaptionWireTests {
    @Test func subscriptionAndConfigurationUseSeparateCommands() throws {
        #expect(try MeetCaptionWire.subscribe(sequence: 7) == Data([18, 8, 8, 7, 26, 4, 8, 1, 16, 1]))
        #expect(try MeetCaptionWire.disable(sequence: 8) == Data([18, 6, 8, 8, 18, 2, 10, 0]))
        let config = try MeetCaptionWire.configure(
            spokenLanguage: "en-US",
            displayLanguage: "fr-FR",
            sequence: 9
        )
        #expect(config == Data([
            18,
            20,
            8,
            9,
            18,
            16,
            10,
            14,
            18,
            5,
            102,
            114,
            45,
            70,
            82,
            26,
            5,
            101,
            110,
            45,
            85,
            83
        ]))
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetCaptionWire.configure(spokenLanguage: "en-US", displayLanguage: "fr FR", sequence: 1)
        }
    }

    @Test func responseMatchesOnlyItsSequenceAndFirstAttempt() throws {
        let subscribed = reply(sequence: 7, result: 4)
        #expect(MeetCaptionWire.matches(subscribed, command: .subscribe, sequence: 7))
        #expect(!MeetCaptionWire.matches(subscribed, command: .configure, sequence: 7))
        #expect(!MeetCaptionWire.matches(subscribed, command: .subscribe, sequence: 8))
        #expect(!MeetCaptionWire.matches(reply(sequence: 7, retry: 1), command: .subscribe, sequence: 7))
        try MeetCaptionWire.confirm(subscribed, command: .subscribe, sequence: 7)
        let rejected = reply(sequence: 9, status: 7)
        #expect(MeetCaptionWire.matches(rejected, command: .configure, sequence: 9))
        #expect(throws: MeetCaptionWire.CommandError.rejected) {
            try MeetCaptionWire.confirm(rejected, command: .configure, sequence: 9)
        }
    }

    @Test(arguments: [MeetCaptionWire.Command.configure, .subscribe])
    func missingStatusRequiresAnExactTypedResult(_ command: MeetCaptionWire.Command) throws {
        let identity = MeetProto.number(1, 7)
        let expected = MeetProto.bytes(UInt64(command.responseField), Data())
        let other = MeetProto.bytes(command == .configure ? 4 : 3, Data())
        let matched = MeetProto.bytes(2, identity + expected)
        #expect(MeetCaptionWire.matches(matched, command: command, sequence: 7))
        try MeetCaptionWire.confirm(matched, command: command, sequence: 7)
        #expect(!MeetCaptionWire.matches(matched, command: command, sequence: 8))
        for invalid in [Data(), other, expected + other, expected + expected] {
            let response = MeetProto.bytes(2, identity + invalid)
            #expect(!MeetCaptionWire.matches(response, command: command, sequence: 7))
        }
        let malformed = MeetProto.bytes(2, identity + MeetProto.number(UInt64(command.responseField), 0))
        #expect(!MeetCaptionWire.matches(malformed, command: command, sequence: 7))
    }

    @Test func captionUpdatesAndDeletesAcknowledgeTheirOwnResourceVersions() throws {
        let caption = MeetProto.number(1, 39) + MeetProto.string(3, "Deux lignes\nBonjour")
            + MeetProto.string(4, "fr-FR") + MeetProto.string(5, "en-US")
        let update = MeetProto.number(1, 130) + MeetProto.bytes(3, caption) + MeetProto.number(10000, 1)
        let optionalSetting = MeetProto.bytes(1, MeetProto.bytes(4, Data()))
        let malformedCaption = MeetProto.bytes(1, MeetProto.number(3, 1))
        let deletion = MeetProto.bytes(
            4,
            MeetProto.number(1, 131)
                + MeetProto.number(2, 2) + MeetProto.number(3, 1)
        )
        let changes = try MeetCaptionWire.updates(
            optionalSetting + malformedCaption + MeetProto.bytes(1, update) + deletion
        ).captions
        try #require(changes.count == 2)
        guard case let .caption(segment) = changes[0], case .deletion = changes[1] else {
            Issue.record("Expected one caption and one deletion")
            return
        }
        #expect(segment.resource.id == 130 && segment.resource.version == 0)
        #expect(segment.text == "Deux lignes\nBonjour" && segment.speaker == "39" && segment.isFinal)
        #expect(segment.displayLanguage == "fr-FR" && segment.spokenLanguage == "en-US")
        let acknowledged = MeetCaptionWire.acknowledge(changes.map(\.resource))
        #expect(acknowledged == Data([10, 5, 8, 130, 1, 24, 1, 10, 7, 8, 131, 1, 16, 2, 24, 1]))
    }

    @Test func captionSettingsMergeLanguageGroupsAndUseASingletonAcknowledgement() throws {
        let pair = MeetProto.string(1, "hu-HU") + MeetProto.string(2, "fr-FR") + MeetProto.string(3, "sk-SK")
        let catalog = MeetProto.string(1, "hu-HU") + MeetProto.string(2, "sk-SK") + MeetProto.bytes(3, pair)
        let message = MeetProto.bytes(1, MeetProto.number(2, 14) + MeetProto.bytes(4, catalog))
        let settings = try #require(MeetCaptionWire.updates(message).settings.first)
        #expect(settings.version == 14 && settings.languages.live == ["hu-HU", "sk-SK"])
        #expect(settings.languages.translations == ["hu-HU": ["fr-FR", "sk-SK"]])
        #expect(MeetCaptionWire.acknowledgeSettings([0, 14]) == Data([10, 2, 32, 1, 10, 4, 16, 14, 32, 1]))
    }

    private func reply(
        sequence: UInt64, retry: UInt64 = 0, status: UInt64 = 0, result: UInt64? = nil
    ) -> Data {
        let identity = MeetProto.number(1, sequence) + MeetProto.number(10001, retry)
        let status = MeetProto.bytes(2, status == 0 ? Data() : MeetProto.number(1, status))
        return MeetProto.bytes(2, identity + status + (result.map { MeetProto.bytes($0, Data()) } ?? Data()))
    }
}
