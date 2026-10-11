import ChatKit
import Foundation
import GChatBridgeCore

/// Routes the shell, `get_self_user_status` (for Mentions me's own id),
/// `get_members` (for the hits' senders) and `batchexecute` - everything
/// else answers an empty 200. Duplicated rather than shared, the same call
/// every other `HTTPTransport` fake in this suite's own files makes.
///
/// Not `private`: every `SearchMessages*Tests.swift` file uses this one
/// transport, so the test struct itself can stay split across files under
/// swiftlint's `file_length` and `type_body_length` - `access_level` on a
/// test-only type costs nothing a production file would pay for.
actor SearchTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Exhausted: Error {}

    private let shell: HTTPResponse
    private let selfStatus: Result<HTTPResponse, any Error>
    private let membersResponse: HTTPResponse
    private var batchResponses: [Result<HTTPResponse, any Error>]
    private(set) var sent: [HTTPRequest] = []
    private var hold: SearchHold?

    init(
        shell: HTTPResponse,
        selfStatus: Result<HTTPResponse, any Error> = .success(SearchTransport.selfStatusResponse("u-me")),
        membersResponse: HTTPResponse = SearchTransport.emptyMembersResponse,
        batchResponses: [Result<HTTPResponse, any Error>] = [],
        hold: SearchHold? = nil
    ) {
        self.shell = shell
        self.selfStatus = selfStatus
        self.membersResponse = membersResponse
        self.batchResponses = batchResponses
        self.hold = hold
    }

    static func selfStatusResponse(_ userID: String) -> HTTPResponse {
        var response = GetSelfUserStatusResponse()
        response.userStatus.userID.id = userID
        return HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: (try? response.serializedBytes()) ?? Data()
        )
    }

    static let emptyMembersResponse = HTTPResponse(
        status: 200, headers: HTTPHeaders([]), body: (try? GetMembersResponse().serializedBytes()) ?? Data()
    )

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        let path = request.url.path
        if path.contains("/mole/world") {
            return shell
        }
        if path.contains("/api/get_self_user_status") {
            return try selfStatus.get()
        }
        if path.contains("/api/get_members") {
            return membersResponse
        }
        if path.contains("batchexecute") {
            if let hold {
                try await hold.wait()
            }
            guard !batchResponses.isEmpty else { throw Exhausted() }
            return try batchResponses.removeFirst().get()
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// A hold that a canceled caller tears down, the same shape
/// `SyncEngineTests`' own `AbortableHold` is (not shared across package
/// boundaries - `CLAUDE.md`'s "a hold must throw when canceled", duplicated
/// here for the reason every transport fake in this suite already is).
actor SearchHold {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var aborted = 0

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.abort() }
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func abort() {
        guard let continuation else { return }
        aborted += 1
        continuation.resume(throwing: CancellationError())
        self.continuation = nil
    }
}
