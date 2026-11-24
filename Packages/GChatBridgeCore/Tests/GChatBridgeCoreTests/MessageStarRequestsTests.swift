import Foundation
import Testing
@testable import GChatBridgeCore

struct MessageStarRequestsTests {
    @Test func listingUsesAnAccountWidePersonalLabelSectionAndItsSortCursor() throws {
        let request = try MessageStarRequests.list(after: "opaque-page")
        let wire: Data = try request.serializedBytes()
        let section = try #require(ProtoFieldScan.payloads(ofField: 2, in: wire).first)
        #expect(APIMethod<PaginatedEntityWorldRequest, PaginatedWorldResponse>.starredMessages
            .name == "paginated_world")
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: section) == [30])
        #expect(ProtoFieldScan.payloads(ofField: 6, in: section).isEmpty)
        #expect(ProtoFieldScan.payloads(ofField: 10, in: section) == [
            Data([0x0A, 4, 0x08, 1, 0x10, 1, 0x12, 2, 0x08, 1])
        ])
        #expect(ProtoFieldScan.payloads(ofField: 11, in: section) == [
            Data([8, 4, 18, 11]) + Data("opaque-page".utf8)
        ])
        var filter = Data([0x0A, 25, 0x08, 3, 0x12, 21, 0x2A, 19, 0x08, 2, 0x12, 7, 0x42, 5])
        filter.append(contentsOf: "label".utf8)
        filter.append(contentsOf: [0x1A, 6, 0x42, 4])
        filter.append(contentsOf: "100G".utf8)
        #expect(ProtoFieldScan.payloads(ofField: 16, in: section) == [filter])
        #expect(ProtoFieldScan.varintValues(ofField: 9, in: wire) == [0])
        #expect(try !MessageStarRequests.list().sections[0].sort.hasSortValue)
    }

    @Test func starAndUnstarCarryTheExactAddressAndOmitTheTimestamp() throws {
        let id = address()
        let star = MessageStarRequests.apply(id)
        let unstar = MessageStarRequests.remove(id)
        #expect(star.messageID == id)
        #expect(unstar.messageID == id)
        #expect(try Data(star.label.serializedBytes()) == Data([8, 1]))
        #expect(unstar.label == star.label)
    }

    @Test func theSectionReturnsOnlyPersonallyStarredAddressedMessages() throws {
        var response = try responseWithStarredSection()
        response.worldSectionResponses[0].hasMoreItems_p = true
        response.worldSectionResponses[0].paginationToken = "next-page"
        var starred = WorldEntity()
        starred.message.id = address()
        starred.message.personalLabelTags = [label(1)]
        var boardPin = starred
        boardPin.message.id.messageID = "pinned"
        boardPin.message.personalLabelTags = [label(2)]
        var missingAddress = starred
        missingAddress.message.clearID()
        var deleted = starred
        deleted.message.deleteTime = 1
        response.worldEntities = [starred, boardPin, missingAddress, deleted, WorldEntity()]
        let page = try MessageStarRequests.page(from: response)
        #expect(page.messages.map(\.id) == [address()])
        #expect(page.nextCursor == "next-page")
    }

    @Test func missingSectionOrPromisedCursorCannotMasqueradeAsAnEmptyPage() throws {
        #expect(throws: MessageStarRequests.Failure.missingStarredSection) {
            try MessageStarRequests.page(from: PaginatedWorldResponse())
        }
        var response = try responseWithStarredSection()
        let empty = try MessageStarRequests.page(from: response)
        #expect(empty.messages.isEmpty)
        #expect(empty.nextCursor == nil)
        response.worldSectionResponses[0].hasMoreItems_p = true
        #expect(throws: MessageStarRequests.Failure.incompletePage) {
            try MessageStarRequests.page(from: response)
        }
        #expect(throws: MessageStarRequests.Failure.invalidCursor) {
            try MessageStarRequests.list(after: "")
        }
    }

    private func responseWithStarredSection() throws -> PaginatedWorldResponse {
        var output = PaginatedWorldResponse()
        var section = WorldSectionResponse()
        section.entityFilter = try #require(MessageStarRequests.list().sections.first?.entityFilter)
        output.worldSectionResponses = [section]
        return output
    }

    private func address() -> MessageId {
        var group = GroupId()
        group.spaceID.spaceID = "space"
        return MessagePinRequests.address(group: group, topic: "thread", message: "message")
    }

    private func label(_ type: Int32) -> MessageLabel {
        var label = MessageLabel()
        label.labelType = type
        return label
    }
}
