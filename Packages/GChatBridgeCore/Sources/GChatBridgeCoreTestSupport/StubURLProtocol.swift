import Foundation

/// A `URLProtocol` that serves queued canned responses and records the requests
/// it was asked for, so API tests need no network.
///
/// Foundation instantiates `URLProtocol` itself, so its state has to be static.
/// To keep concurrently-running test suites from consuming each other's stubs,
/// state is partitioned by the request's **host**: each ``StubSession`` invents a
/// unique host and hands out a matching base URL. Path assertions are
/// unaffected, since the host is not part of the path.
public final class StubURLProtocol: URLProtocol {
    public struct Stub {
        public let status: Int
        public let body: Data
        public let headers: [String: String]

        public init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        public static func json(_ text: String, status: Int = 200) -> Stub {
            Stub(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
        }
    }

    /// One recorded request. The body is captured separately because
    /// `URLSession` converts `httpBody` into `httpBodyStream` before a
    /// `URLProtocol` ever sees the request, so `httpBody` is always nil here and
    /// a POST body would otherwise be unassertable.
    public struct Recorded {
        public let request: URLRequest
        public let body: Data?
    }

    /// A queued outcome: an ordinary answer, or a `URLError` to fail the
    /// request with - the second is what lets a test exercise
    /// `URLSessionTransport`'s classification of a real `URLError` rather
    /// than only the "no stub queued" failure every suite already gets for
    /// free.
    public enum Outcome {
        case success(Stub)
        case failure(URLError.Code)
    }

    /// Host-partitioned stub queues and request logs.
    public final class Registry {
        private let lock = NSLock()
        private var stubs: [String: [Outcome]] = [:]
        private var recorded: [String: [Recorded]] = [:]

        public func enqueue(_ outcome: Outcome, host: String) {
            lock.withLock { stubs[host, default: []].append(outcome) }
        }

        public func take(host: String, recording: Recorded) -> Outcome? {
            lock.withLock {
                recorded[host, default: []].append(recording)
                guard var queue = stubs[host], !queue.isEmpty else { return nil }
                let next = queue.removeFirst()
                stubs[host] = queue
                return next
            }
        }

        public func recordings(host: String) -> [Recorded] {
            lock.withLock { recorded[host] ?? [] }
        }

        public func remove(host: String) {
            lock.withLock {
                stubs[host] = nil
                recorded[host] = nil
            }
        }
    }

    /// Access is serialised by the registry's own lock; `nonisolated(unsafe)`
    /// states that the lock, not the compiler, provides the safety.
    public nonisolated(unsafe) static let registry = Registry()

    // swiftlint:disable static_over_final_class
    // These override NSURLProtocol class methods; `static` cannot override.
    override public class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // swiftlint:enable static_over_final_class

    /// Drains `httpBodyStream`, which is where URLSession puts a body.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override public func startLoading() {
        let host = request.url?.host() ?? ""
        let recording = Recorded(request: request, body: Self.body(of: request))
        guard let outcome = Self.registry.take(host: host, recording: recording) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(
                    .resourceUnavailable,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No stub queued for \(request.url?.absoluteString ?? "?")"
                    ]
                )
            )
            return
        }

        switch outcome {
        case let .failure(code):
            // The failing URL travels on the real error the same way a live
            // one would - `NSURLErrorFailingURLErrorKey` is exactly where
            // `URLSessionTransportTests` proves classification never leaks it.
            client?.urlProtocol(
                self,
                didFailWithError: URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any])
            )
        case let .success(stub):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            // A 3xx with a `Location` is reported as a redirect, the way the
            // loading system's own HTTP protocol reports one, so a session's
            // redirect policy is consulted exactly as it would be live. A
            // policy that refuses it makes the loading system deliver the 3xx
            // itself, which is why the response and body still follow.
            if (300 ..< 400).contains(stub.status),
               let location = stub.headers["Location"],
               let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
                var redirected = request
                redirected.url = target
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override public func stopLoading() {}
}

/// One isolated stubbing context. Swift Testing creates a fresh suite instance
/// per test, so declaring one of these as a suite property gives every test its
/// own queue with no shared state to reset.
public final class StubSession {
    public let host: String
    public let session: URLSession

    public init() {
        host = "stub-\(UUID().uuidString.lowercased()).invalid"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    deinit {
        StubURLProtocol.registry.remove(host: host)
    }

    public var baseURL: URL {
        URL(string: "https://\(host)/v1")!
    }

    public func enqueue(_ stub: StubURLProtocol.Stub) {
        StubURLProtocol.registry.enqueue(.success(stub), host: host)
    }

    /// Fails the next request with `code` instead of answering it - what a
    /// test reaches for to exercise `URLSessionTransport`'s classification of
    /// a real `URLError`, rather than only the "no stub queued" one every
    /// suite gets without asking.
    public func enqueueFailure(_ code: URLError.Code) {
        StubURLProtocol.registry.enqueue(.failure(code), host: host)
    }

    public func enqueue(json: String, status: Int = 200) {
        enqueue(.json(json, status: status))
    }

    public var recordings: [StubURLProtocol.Recorded] {
        StubURLProtocol.registry.recordings(host: host)
    }

    public var requests: [URLRequest] {
        recordings.map(\.request)
    }
}
