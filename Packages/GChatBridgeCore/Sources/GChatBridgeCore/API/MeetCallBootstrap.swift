import Foundation

public enum MeetCallRedirect: Sendable, Equatable {
    case accounts
    case meet
    case otherGoogle
    case elsewhere
    case unknown
}

public enum MeetCallBootstrapError: Error, Sendable, Equatable {
    case redirected(Int, MeetCallRedirect)
    case httpStatus(Int)
    case missingClientKey
    case invalidRTCClientMetadata
}

/// Reads the current public Meet client key from a page shell. The captured
/// `/call` shell contained four candidates: the RPC key appeared eleven times,
/// and each other key appeared once. A tie or a changed shape stops the probe
/// instead of guessing a key for a request that could ring someone.
public enum MeetCallPageKey {
    public static func extract(from html: Data) -> String? {
        guard let text = String(data: html, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: "AIza[0-9A-Za-z_-]{35}")
        else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var counts: [String: Int] = [:]
        for match in expression.matches(in: text, range: range) {
            guard let found = Range(match.range, in: text) else { continue }
            counts[String(text[found]), default: 0] += 1
        }
        let repeated = counts.filter { $0.value >= 2 }
        guard repeated.count == 1 else { return nil }
        return repeated.first?.key
    }
}

/// A read-only Meet shell fetch; it neither resolves a DM nor creates a call.
/// The synthetic `mc` is just enough to request the shell, and is never run as
/// a page. Whether an authenticated server accepts it remains a live check.
public struct MeetCallBootstrap: Sendable {
    let transport: any HTTPTransport
    let credentials: SessionCredentials

    public init(transport: any HTTPTransport, credentials: SessionCredentials) {
        self.transport = transport
        self.credentials = credentials
    }

    public func loadConfiguration(
        accountIndex: Int, userAgent: String
    ) async throws -> MeetCallConfiguration {
        var components = URLComponents(string: "https://meet.google.com/call")!
        components.queryItems = [
            URLQueryItem(name: "authuser", value: String(accountIndex)),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "mc", value: "CgA="),
            URLQueryItem(name: "origin", value: "https://chat.google.com")
        ]
        let page = components.url!
        let request = HTTPRequest(
            url: page,
            headers: HTTPHeaders([("User-Agent", userAgent)]),
            traceLabel: "meet-call-bootstrap",
            followsRedirects: false,
            maxBodyBytes: 2_000_000
        )
        let response = try await transport.send(credentials.authorising(request))
        await credentials.absorb(response.headers, from: page)
        if (300 ..< 400).contains(response.status) {
            throw MeetCallBootstrapError.redirected(
                response.status, Self.redirect(in: response.headers, relativeTo: page)
            )
        }
        guard response.status == 200 else { throw MeetCallBootstrapError.httpStatus(response.status) }
        guard let key = MeetCallPageKey.extract(from: response.body)
        else { throw MeetCallBootstrapError.missingClientKey }
        let streamMetadata = MeetStreamClientMetadata.extract(response.body)
        guard let rtcClient = MeetCallRTCClient.extract(from: response.body),
              let configuration = MeetCallConfiguration(
                  apiKey: key, accountIndex: accountIndex,
                  referer: page, userAgent: userAgent,
                  rtcClientID: rtcClient, debugID: randomDebugID(),
                  streamApplication: streamMetadata?.application, streamClientVersion: streamMetadata?.version
              )
        else { throw MeetCallBootstrapError.invalidRTCClientMetadata }
        return configuration
    }

    private func randomDebugID() -> String {
        "dbg_web_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    /// Reduce a Location to its destination class. A Google sign-in redirect
    /// carries one-time parameters; no part of the URL reaches a report.
    static func redirect(in headers: HTTPHeaders, relativeTo page: URL) -> MeetCallRedirect {
        guard let location = headers["Location"],
              let destination = URL(string: location, relativeTo: page)?.absoluteURL,
              let host = destination.host?.lowercased()
        else { return .unknown }
        switch host {
        case "accounts.google.com": return .accounts
        case "meet.google.com": return .meet
        default:
            if host == "google.com" || host.hasSuffix(".google.com") {
                return .otherGoogle
            }
            return .elsewhere
        }
    }
}
