import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

@Suite("WorldRequestLadder")
struct WorldRequestLadderTests {
    @Test func thereAreFourRungs() {
        #expect(WorldRequestLadder.rungs.count == 4)
    }

    /// Rung 1 is §3.6's control and is *expected to fail*. A ladder without it
    /// cannot tell "shape 2 fixed it" from "this account, credential or client
    /// differs from the run that produced §3.6".
    @Test func rungOneIsTheControlAndCarriesNoSectionRequests() {
        let control = WorldRequestLadder.rungs[0].request
        #expect(control.fetchFromUserSpaces == true)
        #expect(control.worldSectionRequests.isEmpty)
        #expect(control.hasRequestHeader == true)
    }

    @Test func rungTwoAddsTheSectionRequestBothReferencesShare() {
        let rung = WorldRequestLadder.rungs[1].request
        #expect(rung.worldSectionRequests.count == 1)
        #expect(rung.worldSectionRequests[0].pageSize == 999)
    }

    @Test func rungThreeAddsSnippetsForUnnamedRooms() {
        #expect(WorldRequestLadder.rungs[2].request.fetchSnippetsForUnnamedRooms == true)
    }

    @Test func rungFourAddsTheMaugclibFetchOption() {
        #expect(WorldRequestLadder.rungs[3].request.fetchOptions == [.excludeGroupLite])
    }

    @Test func theFourRungsAreActuallyDifferentRequests() throws {
        let encoded = try WorldRequestLadder.rungs.map { rung -> Data in
            try rung.request.serializedBytes()
        }
        #expect(Set(encoded).count == 4)
    }

    @Test func everyRungIsAttributedToASource() {
        #expect(WorldRequestLadder.rungs.allSatisfy { !$0.source.isEmpty })
    }

    @Test func aRunReportsTheFieldNumbersThatCameBack() async throws {
        // §3.6's observed world response: field 11, varint 21.
        let body = Data([0x58, 0x15])
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
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        #expect(results.count == 4)
        #expect(results[0].fields == [ProtoField(number: 11, wireType: 0, byteCount: 1)])
        #expect(results[0].encoding == .raw)
        #expect(results[0].failure == nil)
    }

    /// A rung that fails must not stop the ladder: the point is to compare all
    /// four, and a 403 on rung 1 is itself a result.
    @Test func aFailingRungIsRecordedAndTheLadderContinues() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15]))
        ])
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        #expect(results.count == 4)
        #expect(results[0].failure != nil)
        #expect(results[1].fields.isEmpty == false)
    }

    /// The standing rule: counts, lengths, statuses and field numbers - never a
    /// value. A world response carries real conversation names.
    @Test func theReportCarriesNoResponseBytes() {
        let results = [
            WorldRungResult(
                label: "rung 1",
                status: 200,
                byteCount: 2,
                encoding: .raw,
                fields: [ProtoField(number: 11, wireType: 0, byteCount: 1)],
                truncated: false,
                failure: nil
            )
        ]
        let text = WorldRequestLadder.report(results)
        #expect(text.contains("11"))
        #expect(text.contains("200"))
        #expect(text.contains("2 wire bytes"))
    }

    // MARK: - worldItemFields: §20.4's nested-shape gap

    /// A rung whose response carries `world_items` (field 4) reports the
    /// field numbers found *inside* each one, not only at the top level.
    @Test func aRunReportsTheFieldsInsideEachWorldItem() async throws {
        // Top level: field 4 (world_items), containing field 1 varint 9 and
        // field 5 (length 2, "hi").
        let item = Data([0x08, 0x09, 0x2A, 0x02, 0x68, 0x69])
        var body = Data([0x22, UInt8(item.count)])
        body += item
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
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        #expect(results[0].worldItemFields == [[
            ProtoField(number: 1, wireType: 0, byteCount: 1),
            ProtoField(number: 5, wireType: 2, byteCount: 2)
        ]])
    }

    /// The control is expected to carry no `world_items` at all - `[]`, not a
    /// crash or a truncated read.
    @Test func aRungWithNoWorldItemsReportsAnEmptyNestedShape() async throws {
        let transport = FakeHTTPTransport(responses: (0 ..< 4).map { _ in
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15]))
        })
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        #expect(results[0].worldItemFields.isEmpty)
    }

    /// A rung with no parseable candidate at all - a failed call - must not
    /// crash computing the nested shape; it is simply empty, the same as the
    /// top-level `fields`.
    @Test func aFailingRungHasAnEmptyNestedShapeRatherThanCrashing() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15])),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x58, 0x15]))
        ])
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        #expect(results[0].worldItemFields.isEmpty)
    }
}
