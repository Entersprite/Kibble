import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The per-task delegate behind `HTTPRequest.followsRedirects == false`.
///
/// Refusing a redirect makes the loading system complete the task with the
/// 3xx response and its body, which is what the caller asked for. A per-task
/// delegate rather than a session-wide one, so every other request keeps the
/// session's ordinary behaviour.
///
/// **Measured on Darwin only** (`findings.md` §51.2: the live 302 came back
/// as the response). Whether `FoundationNetworking` honours a per-task
/// redirect delegate is `[Verify]`, and matters before a bridge server runs on
/// Linux: if it does not, the 302 would be followed with the hand-set
/// `Cookie` header on it. A test on Linux, before that server exists.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = RefuseRedirects()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
