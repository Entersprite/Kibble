import Foundation
import Testing
@testable import GChatBridgeCoreTestSupport

/// Two non-obvious properties of this stub are load-bearing and easy to lose in
/// a refactor: state is partitioned per host, so Swift Testing's parallel suites
/// cannot consume each other's stubs; and request bodies are read from
/// `httpBodyStream`, because URLSession converts `httpBody` to a stream before a
/// URLProtocol ever sees it - without which POST bodies are simply unassertable.
/// Both are pinned here.
@Suite("Stub URL protocol")
struct StubURLProtocolTests {
    @Test("a queued response is returned to the caller")
    func servesQueuedResponse() async throws {
        let stub = StubSession()
        stub.enqueue(json: #"{"ok":true}"#)

        let (data, response) = try await stub.session.data(
            from: stub.baseURL.appending(path: "probe")
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("ok"))
    }

    @Test("POST bodies survive URLSession converting them to a stream")
    func capturesPostBody() async throws {
        let stub = StubSession()
        stub.enqueue(json: "{}")

        var request = URLRequest(url: stub.baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"text":"hello"}"#.utf8)
        _ = try await stub.session.data(for: request)

        let recorded = try #require(stub.recordings.last)
        let body = try #require(recorded.body, "body was nil - the httpBodyStream drain regressed")
        let text = try #require(String(bytes: body, encoding: .utf8))
        #expect(text.contains("hello"))
    }

    @Test("two sessions do not consume each other's stubs")
    func hostPartitioning() async throws {
        let first = StubSession()
        let second = StubSession()
        #expect(first.host != second.host)

        first.enqueue(.init(status: 201))
        second.enqueue(.init(status: 202))

        // Drained out of order on purpose: a shared queue would hand the 201 to
        // whoever asked first, and this would fail.
        let (_, secondResponse) = try await second.session.data(
            from: second.baseURL.appending(path: "x")
        )
        let (_, firstResponse) = try await first.session.data(
            from: first.baseURL.appending(path: "x")
        )

        #expect((secondResponse as? HTTPURLResponse)?.statusCode == 202)
        #expect((firstResponse as? HTTPURLResponse)?.statusCode == 201)
    }
}
