import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

@Suite("TopicsRequestLadder")
struct TopicsRequestLadderTests {
    private func group(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    private func rungs(_ id: String = "s-1") -> [TopicsRequestLadder.Rung] {
        TopicsRequestLadder.rungs(for: group(id))
    }

    @Test func thereAreFourRungs() {
        #expect(TopicsRequestLadder.rungs(for: group("s-1")).count == 4)
    }

    /// Rung 1 is the control and carries nothing beyond identity - expected to
    /// under-perform, the same role `WorldRequestLadder`'s rung 1 plays.
    @Test func rungOneIsTheControlAndCarriesOnlyHeaderAndGroupID() {
        let control = TopicsRequestLadder.rungs(for: group("s-1"))[0].request
        #expect(control.hasRequestHeader == true)
        #expect(control.groupID.spaceID.spaceID == "s-1")
        #expect(control.hasPageSizeForTopics == false)
        #expect(control.hasPageSizeForReplies == false)
        #expect(control.fetchOptions.isEmpty)
    }

    @Test func rungTwoAddsThePageSizeForTopics() {
        let rung = TopicsRequestLadder.rungs(for: group("s-1"))[1].request
        #expect(rung.pageSizeForTopics == 50)
        #expect(rung.hasPageSizeForReplies == false)
    }

    @Test func rungThreeAddsThePageSizeForReplies() {
        let rung = TopicsRequestLadder.rungs(for: group("s-1"))[2].request
        #expect(rung.pageSizeForTopics == 50)
        #expect(rung.pageSizeForReplies == 50)
        #expect(rung.fetchOptions.isEmpty)
    }

    @Test func rungFourAddsTheFetchOptions() {
        let rung = TopicsRequestLadder.rungs(for: group("s-1"))[3].request
        #expect(rung.fetchOptions == [.user, .totalMessageCounts, .readReceipts])
    }

    @Test func everyRungCarriesTheSameGroupID() {
        let rungs = TopicsRequestLadder.rungs(for: group("s-1"))
        #expect(rungs.allSatisfy { $0.request.groupID.spaceID.spaceID == "s-1" })
    }

    /// Two different groups must not collapse onto the same request - a
    /// ladder that ignored the group parameter would still compile and still
    /// pass every other test here.
    @Test func differentGroupsProduceDifferentRequests() throws {
        let forS1: Data = try TopicsRequestLadder.rungs(for: group("s-1"))[1].request.serializedBytes()
        let forS2: Data = try TopicsRequestLadder.rungs(for: group("s-2"))[1].request.serializedBytes()
        #expect(forS1 != forS2)
    }

    @Test func theFourRungsAreActuallyDifferentRequests() throws {
        let encoded = try TopicsRequestLadder.rungs(for: group("s-1")).map { rung -> Data in
            try rung.request.serializedBytes()
        }
        #expect(Set(encoded).count == 4)
    }

    @Test func everyRungIsAttributedToASource() {
        #expect(TopicsRequestLadder.rungs(for: group("s-1")).allSatisfy { !$0.source.isEmpty })
    }

    /// `minimumViable(for:)` is what production will send - asserting
    /// byte-identical serialisation, not just equal field values, is what
    /// makes the two provably unable to drift apart, the same guarantee
    /// `WorldRequestLadder.minimumViable`'s own test pins.
    @Test func minimumViableSerializesByteIdenticallyToRungsIndex1() throws {
        let viaAccessor: Data = try TopicsRequestLadder.minimumViable(for: group("s-1")).request
            .serializedBytes()
        let viaIndex: Data = try TopicsRequestLadder.rungs(for: group("s-1"))[1].request
            .serializedBytes()
        #expect(viaAccessor == viaIndex)
    }

    @Test func aRunReportsTheFieldNumbersThatCameBack() async throws {
        // A minimal ListTopicsResponse: field 4 (contains_first_topic), varint 1.
        let body = Data([0x20, 0x01])
        let transport = FakeHTTPTransport(responses: (0 ..< 4).map { _ in
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
        })
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await TopicsRequestLadder.run(rungs(), with: client)
        #expect(results.count == 4)
        #expect(results[0].fields == [ProtoField(number: 4, wireType: 0, byteCount: 1)])
        #expect(results[0].encoding == .raw)
        #expect(results[0].failure == nil)
    }

    /// A rung that fails must not stop the ladder.
    @Test func aFailingRungIsRecordedAndTheLadderContinues() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01]))
        ])
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await TopicsRequestLadder.run(rungs(), with: client)
        #expect(results.count == 4)
        #expect(results[0].failure != nil)
        #expect(results[1].fields.isEmpty == false)
    }

    /// The standing rule: counts, lengths, statuses and field numbers - never
    /// a value. A `list_topics` response carries real message content.
    @Test func theReportCarriesNoResponseBytes() {
        let results = [
            TopicsRungResult(
                label: "rung 1",
                status: 200,
                byteCount: 2,
                encoding: .raw,
                fields: [ProtoField(number: 4, wireType: 0, byteCount: 1)],
                truncated: false,
                failure: nil
            )
        ]
        let text = TopicsRequestLadder.report(results)
        #expect(text.contains("4"))
        #expect(text.contains("200"))
        #expect(text.contains("2 wire bytes"))
    }

    // MARK: - topicFields: the nested-shape scan

    /// A rung whose response carries `topics` (field 1) reports the field
    /// numbers found *inside* each one, not only at the top level.
    @Test func aRunReportsTheFieldsInsideEachTopic() async throws {
        // Top level: field 1 (topics), containing field 2 varint 9 (sort_time-ish)
        // and field 12 (length 2, "hi").
        let topic = Data([0x10, 0x09, 0x62, 0x02, 0x68, 0x69])
        var body = Data([0x0A, UInt8(topic.count)])
        body += topic
        let transport = FakeHTTPTransport(responses: (0 ..< 4).map { _ in
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
        })
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await TopicsRequestLadder.run(rungs(), with: client)
        #expect(results[0].topicFields == [[
            ProtoField(number: 2, wireType: 0, byteCount: 1),
            ProtoField(number: 12, wireType: 2, byteCount: 2)
        ]])
    }

    /// The control is expected to carry no `topics` at all - `[]`, not a
    /// crash or a truncated read.
    @Test func aRungWithNoTopicsReportsAnEmptyNestedShape() async throws {
        let transport = FakeHTTPTransport(responses: (0 ..< 4).map { _ in
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01]))
        })
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await TopicsRequestLadder.run(rungs(), with: client)
        #expect(results[0].topicFields.isEmpty)
    }

    /// A rung with no parseable candidate at all - a failed call - must not
    /// crash computing the nested shape; it is simply empty.
    @Test func aFailingRungHasAnEmptyNestedShapeRatherThanCrashing() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x20, 0x01]))
        ])
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await TopicsRequestLadder.run(rungs(), with: client)
        #expect(results[0].topicFields.isEmpty)
    }
}
