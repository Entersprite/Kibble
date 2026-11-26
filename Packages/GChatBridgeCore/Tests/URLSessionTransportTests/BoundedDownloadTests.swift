import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

@Suite(.timeLimit(.minutes(1)))
struct BoundedDownloadTests {
    let stub = StubSession()

    func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func ownedDestinationStreamsThroughTheProtocolWitness() async throws {
        let bytes = Data(repeating: 42, count: 200_000)
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: bytes))
        let transport: any HTTPTransport = URLSessionTransport(session: stub.session)
        let destination = file()
        let progress = ProgressLog()
        let response = try await transport.download(
            HTTPRequest(url: stub.baseURL, maxBodyBytes: bytes.count), destination: destination
        ) { progress.append($0, $1) }
        #expect(response.body.isEmpty)
        #expect(try Data(contentsOf: destination) == bytes)
        // A fallback whole-body implementation would report only one step.
        #expect(progress.values.count >= 4)
        #expect(progress.last?.written == bytes.count)
    }

    @Test func declaredOversizeRefusesBeforeAnyFileOrProgress() async throws {
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: Data([1]), headers: ["Content-Length": "1000"]))
        let transport: any HTTPTransport = URLSessionTransport(session: stub.session)
        let destination = file()
        let progress = ProgressLog()
        await #expect(throws: HTTPBodyTooLarge(limit: 10)) {
            try await transport.download(
                HTTPRequest(url: stub.baseURL, maxBodyBytes: 10),
                destination: destination
            ) {
                progress.append($0, $1)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(progress.values.isEmpty)
    }

    @Test func unstatedOversizeStopsAfterOneBoundedWriteAndRemovesOnlyItsPartialFile() async throws {
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: Data(repeating: 42, count: 70000)))
        let transport: any HTTPTransport = URLSessionTransport(session: stub.session)
        let destination = file()
        let progress = ProgressLog()
        await #expect(throws: HTTPBodyTooLarge(limit: 65536)) {
            try await transport.download(
                HTTPRequest(url: stub.baseURL, maxBodyBytes: 65536),
                destination: destination
            ) {
                progress.append($0, $1)
            }
        }
        #expect(progress.values.map(\.written) == [65536])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(arguments: [0, 65536, 70000])
    func exactCeilingAcceptsEmptyChunkBoundaryAndPartialFinalChunk(_ count: Int) async throws {
        let body = Data(repeating: 7, count: count)
        stub.enqueue(StubURLProtocol.Stub(status: 200, body: body))
        let transport: any HTTPTransport = URLSessionTransport(session: stub.session)
        let destination = file()
        _ = try await transport.download(
            HTTPRequest(url: stub.baseURL, maxBodyBytes: count), destination: destination,
            progress: { _, _ in }
        )
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func anExistingDestinationIsPreservedWithoutSendingARequest() async throws {
        let destination = file()
        let original = Data("keep".utf8)
        try original.write(to: destination)
        let transport: any HTTPTransport = URLSessionTransport(session: stub.session)
        await #expect(throws: TransportFailure.cannotWriteFile) {
            try await transport.download(HTTPRequest(url: stub.baseURL), destination: destination) { _, _ in }
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(stub.requests.isEmpty)
        // The lower-level creator is exclusive too, including after a network await.
        #expect(throws: TransportFailure.cannotWriteFile) {
            try URLSessionTransport.openForWriting(destination)
        }
        #expect(try Data(contentsOf: destination) == original)
    }
}
