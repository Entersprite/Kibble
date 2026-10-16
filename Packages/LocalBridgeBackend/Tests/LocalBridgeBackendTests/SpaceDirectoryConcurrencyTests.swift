import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private actor HeldSpaceMetadataTransport: HTTPTransport {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var holding = true
    private(set) var active = 0
    private(set) var maximumActive = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.lastPathComponent == "search_space_directory" {
            var response = SearchSpaceDirectoryResponse()
            response.spaces = (0 ..< 14).map { index in
                var row = SearchSpaceDirectoryResponse.Summary()
                row.groupID.spaceID.spaceID = "space-\(index)"
                row.name = "Space \(index)"; row.membershipState = .memberNotAMember
                return row
            }
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
        }
        let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
        active += 1; maximumActive = max(maximumActive, active)
        if holding {
            await withCheckedContinuation { pending.append($0) }
        }
        active -= 1
        var response = GetGroupResponse()
        response.group.groupID = input.groupID
        response.group.name = input.groupID.spaceID.spaceID
        response.group.attributeCheckerGroupType = .flatRoom
        response.membershipState = .memberInvited
        return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw CancellationError()
    }

    func release() {
        holding = false
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SpaceDirectoryConcurrencyTests {
    @Test func detailReadsOverlapWithinABoundAndPreserveDirectoryOrder() async throws {
        let transport = HeldSpaceMetadataTransport()
        let reader = makeReader(transport)
        let task = Task { try await reader.discover("", token: nil, key: "test") }
        for _ in 0 ..< 200 where await transport.active < 6 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.active == 6)
        await transport.release()
        let page = try await task.value
        #expect(page.spaces.map(\.conversation.id.rawValue) == (0 ..< 14).map { "space/space-\($0)" })
        #expect(await transport.maximumActive == 6)
    }

    @Test func cancelledMetadataCannotProduceADirectoryPage() async throws {
        let transport = HeldSpaceMetadataTransport()
        let reader = makeReader(transport)
        let task = Task { try await reader.discover("", token: nil, key: "test") }
        for _ in 0 ..< 200 where await transport.active == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await transport.active > 0)
        task.cancel()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.active == 0)
    }

    private func makeReader(_ transport: HeldSpaceMetadataTransport) -> SpaceDirectoryReader {
        SpaceDirectoryReader(client: ProtoAPIClient(
            transport: transport, endpoints: ChatEndpoints(),
            credentials: SessionCredentials(SearchBackendSupport.cookies), xsrfToken: nil
        ))
    }
}
