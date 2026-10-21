import Foundation
import Testing
@testable import GChatBridgeCore

struct ChannelRevisionRecoveryTests {
    @Test func primaryBodyUsesOuterTagAndPrecedesEmbeddedBodies() throws {
        let raw = #"[[[null,null,6,{"6":[]},null,null,["1700000000000001","1700000000000000"],[{"12":20}]]]]"#
        let event = try #require(ChannelEvent(ChannelArray(aid: 1, data: PBLiteValue(json: Data(raw.utf8)))))
        #expect(event.bodies.map(\.typeTag) == [6, 20])
        #expect(event.revision == ChannelEventRevision(
            scope: .group, timestamp: 1_700_000_000_000_001, previousTimestamp: 1_700_000_000_000_000
        ))
    }

    @Test func trailingDictionaryRevisionPreservesInt64Precision() throws {
        // High fields may live in the envelope's final dictionary.
        let eventRaw = "[[[null,{\"6\":[\"9007199254740993\",\"9007199254740992\"],"
            + "\"8\":[{\"12\":6}]}]]]"
        let event = try #require(ChannelEvent(ChannelArray(
            aid: 1,
            data: PBLiteValue(json: Data(eventRaw.utf8))
        )))
        #expect(event.revision?.timestamp == 9_007_199_254_740_993)
        #expect(event.bodies.first?.typeTag == 6)
    }

    @Test func recoveryRequestsUseTheExpectedEndpointsHeaderAndBoundedRange() throws {
        var group = GroupId()
        group.spaceID.spaceID = "fixture"
        let request = CatchUpRequests.group(group, from: 100, through: 200)
        #expect(APIMethod<CatchUpGroupRequest, CatchUpResponse>.catchUpGroup.name == "catch_up_group")
        #expect(APIMethod<CatchUpUserRequest, CatchUpResponse>.catchUpUser.name == "catch_up_user")
        #expect(request.hasRequestHeader)
        #expect(request.groupID == group)
        #expect(request.range.fromRevisionTimestamp == 100)
        #expect(request.range.toRevisionTimestamp == 200)
        #expect(request.pageSize == 100)
        #expect(request.cutoffSize == 1000)
        let fields = try ProtoFieldScan.fields(in: request.serializedData()).fields
        #expect(fields.contains { $0.number == 100 })
    }
}
