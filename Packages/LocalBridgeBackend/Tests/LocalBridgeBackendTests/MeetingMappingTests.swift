import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetingMappingTests {
    @Test func sparseOwnerLayoutKeepsProviderIdentityAndCombinesSameTitleParentsForNavigation() throws {
        let first = try group(id: "chat-current", event: "series_alpha_20261012T090000Z")
        let older = try group(id: "chat-prior", event: "series_alpha_20261008T090000Z")
        let control = try group(id: "chat-unrelated", event: "series_beta_20261012T090000Z")
        let current = try #require(ManagementMapping.conversation(first))
        let prior = try #require(ManagementMapping.conversation(older))
        let unrelated = try #require(ManagementMapping.conversation(control))
        #expect(current.id == .init("space/chat-current"))
        #expect(prior.id == .init("space/chat-prior"))
        #expect(current.meeting?.seriesID == prior.meeting?.seriesID)
        #expect(current.meeting?.seriesID != unrelated.meeting?.seriesID)
        #expect(current.meeting?.occurrenceID != prior.meeting?.occurrenceID)
        #expect(current.meeting?.originalStart != prior.meeting?.originalStart)
        #expect(current.title == "Weekly Planning - Oct 12")
        #expect(current.meeting?.seriesTitle == "Weekly Planning")
        let series = MeetingSeries.build([current, prior, unrelated])
        #expect(series.count == 1)
        #expect(series.first?.occurrences.count == 3)
    }

    @Test func worldAndDetailDecodeTheSameLiteralWireFields() throws {
        // Literal protobuf field tags, independent of the generated serializer.
        let metadata = bytes(1, "base_20261012T090000Z") + bytes(2, "Weekly Planning") +
            bytes(3, bytes(1, varintField(1, 1_791_795_600))) + bytes(7, "opaque-context")
        let integration = bytes(107, bytes(3, metadata))
        let groupID = bytes(1, bytes(1, "chat-current"))
        let groupBytes = bytes(1, groupID) + varintField(33, 10) + bytes(29, integration)
        let worldBytes = bytes(1, groupID) + varintField(19, 10) + bytes(17, integration)
        let detail = try #require(ManagementMapping.conversation(Group(serializedBytes: groupBytes)))
        let world = try #require(WorldMapping.conversation(from: WorldItemLite(serializedBytes: worldBytes)))
        #expect(detail.meeting != nil)
        #expect(world.meeting == detail.meeting)
        #expect(detail.meeting?.scheduledStart == Date(timeIntervalSince1970: 1_791_795_600))
        let pblite = try group(id: "chat-current", event: "base_20261012T090000Z")
        #expect(pblite.spaceIntegrationPayloads.count == 2)
        #expect(pblite.spaceIntegrationPayloads[1].meetingChat.calendarEvent
            .eventID == "base_20261012T090000Z")
        #expect(pblite.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start.timestamp
            .seconds == 1_791_795_600)
    }

    @Test func movedOccurrenceKeepsIdentityAndOriginalTime() throws {
        let group = try group(id: "chat-current", event: "base_20261012T090000Z")
        let original = try #require(ManagementMapping.conversation(group)?.meeting)
        var moved = group
        moved.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start.timestamp.seconds += 7200
        moved.spaceIntegrationPayloads[1].meetingChat.calendarEvent.title = "Renamed planning"
        let changed = try #require(ManagementMapping.conversation(moved)?.meeting)
        #expect(changed.seriesID == original.seriesID)
        #expect(changed.occurrenceID == original.occurrenceID)
        #expect(changed.originalStart == original.originalStart)
        #expect(changed.scheduledStart == original.scheduledStart.addingTimeInterval(7200))
        #expect(changed.seriesTitle == "Renamed planning")
    }

    @Test func equalBasesInDifferentOpaqueContextsRemainSeparate() throws {
        let first = try group(id: "chat-current", event: "base_20261012T090000Z")
        var other = first
        other.spaceIntegrationPayloads[1].meetingChat.calendarEvent.identityContext = "another-context"
        #expect(ManagementMapping.conversation(first)?.meeting?.seriesID !=
            ManagementMapping.conversation(other)?.meeting?.seriesID)
    }

    @Test func sameTitleParentsInDifferentOpaqueContextsStaySeparateForNavigation() throws {
        let first = try group(id: "chat-current", event: "series_alpha_20261012T090000Z")
        var other = try group(id: "chat-other", event: "series_beta_20261012T090000Z")
        other.spaceIntegrationPayloads[1].meetingChat.calendarEvent.identityContext = "another-context"
        let current = try #require(ManagementMapping.conversation(first))
        let separate = try #require(ManagementMapping.conversation(other))
        #expect(current.meeting?.seriesScope == "opaque-context")
        #expect(separate.meeting?.seriesScope == "another-context")
        #expect(MeetingSeries.build([current, separate]).count == 2)
    }

    @Test func allDayOccurrencesSurviveASkippedMidnightAndAMissingTimeZone() throws {
        var value = try group(id: "chat-current", event: "base_20240908")
        var start = MeetingChatDateTime()
        start.date.year = 2024
        start.date.month = 9
        start.date.day = 8
        start.timeZone = "America/Santiago"
        value.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start = start
        let santiago = try #require(ManagementMapping.conversation(value)?.meeting)
        #expect(santiago.scheduledStart == Date(timeIntervalSince1970: 1_725_768_000))
        #expect(santiago.originalStart == santiago.scheduledStart)
        start.clearTimeZone()
        value.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start = start
        let utc = try #require(TimeZone(identifier: "UTC"))
        let floating = try #require(MeetingMapping.occurrence(
            in: value.spaceIntegrationPayloads,
            floatingZone: utc
        ))
        #expect(floating.scheduledStart == Date(timeIntervalSince1970: 1_725_753_600))
        #expect(floating.originalStart == floating.scheduledStart)
    }

    @Test func absentAndMalformedMetadataNeverGroupsByTitle() throws {
        let valid = try group(id: "chat-current", event: "base_20261012T090000Z")
        var variants = [Group]()
        var changed = valid; changed.spaceIntegrationPayloads = []; variants.append(changed)
        changed = valid; changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.clearIdentityContext()
        variants.append(changed)
        changed = valid; changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.title = " "
        variants.append(changed)
        changed = valid; changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.clearStart()
        variants.append(changed)
        changed = valid; changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start.timestamp
            .nanos = -1
        variants.append(changed)
        changed = valid
        changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start.timestamp.clearSeconds()
        variants.append(changed)
        changed = valid; changed.spaceIntegrationPayloads[1].meetingChat.calendarEvent.start.date.year = 2026
        variants.append(changed)
        for variant in variants {
            #expect(ManagementMapping.conversation(variant)?.meeting == nil)
        }
    }

    @Test func conflictingIntegrationsRefuseGroupingWhileIdenticalDuplicatesAreHarmless() throws {
        var value = try group(id: "chat-current", event: "base_20261012T090000Z")
        value.spaceIntegrationPayloads.append(value.spaceIntegrationPayloads[1])
        #expect(ManagementMapping.conversation(value)?.meeting != nil)
        value.spaceIntegrationPayloads[2].meetingChat.calendarEvent.eventID = "other_20261012T090000Z"
        #expect(ManagementMapping.conversation(value)?.meeting == nil)
    }

    @Test func nonMeetKindsNeverAdoptMeetingMetadataAndPartialDetailsKeepKnownMetadata() throws {
        let value = try group(id: "chat-current", event: "base_20261012T090000Z")
        let known = try #require(ManagementMapping.conversation(value))
        for kind in [Conversation.Kind.space, .directMessage, .appDirectMessage] {
            let fallback = Conversation(id: known.id, kind: kind)
            #expect(ManagementMapping.conversation(value, fallback: fallback)?.meeting == nil)
        }
        var partial = value; partial.spaceIntegrationPayloads = []
        #expect(ManagementMapping.conversation(partial, fallback: known)?.meeting == known.meeting)
        partial.spaceIntegrationPayloads = [value.spaceIntegrationPayloads[0]]
        #expect(ManagementMapping.conversation(partial, fallback: known)?.meeting == nil)
    }

    private func group(id: String, event: String) throws -> Group {
        // The observed Group57 layout: current warning integration followed by the
        // event-bearing integration, both stored in trailing sparse field107.
        var fields = Array(repeating: PBLiteValue.null, count: 57)
        fields[0] = .array([.array([.string(id)])])
        fields[1] = .string("Weekly Planning - Oct 12")
        fields[32] = .number(.integer(10))
        let time = PBLiteValue.array([
            .array([.number(.integer(1_791_795_600))]), .null, .string("UTC")
        ])
        let metadata = PBLiteValue.array([
            .string(event), .string("Weekly Planning"), time, time, .null, .null,
            .string("opaque-context")
        ])
        let warning = PBLiteValue.array([.number(.integer(1)), .object(["107": .array([])])])
        let meeting = PBLiteValue.array([.number(.integer(2)), .object([
            "107": .array([.null, .null, metadata])
        ])])
        fields[28] = .array([warning, meeting])
        let decoded = PBLiteDecoder.decode(Group.self, from: .array(fields))
        #expect(!decoded.issues.contains { $0.kind != .unknownField })
        return decoded.message
    }

    private func bytes(_ field: Int, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    private func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field * 8 + 2)) + varint(UInt64(value.count)) + value
    }

    private func varintField(_ field: Int, _ value: UInt64) -> Data {
        varint(UInt64(field * 8)) + varint(value)
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            result.append(value == 0 ? byte : byte | 128)
        } while value != 0
        return result
    }
}
