import Foundation

/// The `RequestHeader` every `/api/` request carries.
///
/// `findings.md` §3.6 hand-encoded `client_type: WEB` and
/// `client_version: 2440378181258` and had them accepted, which is what
/// confirmed the hand-written proto's field numbers where they were exercised.
/// Nothing beyond those two is set here: the reference also sends
/// `client_feature_capabilities`, and that has **not** been observed to matter.
/// Adding an unverified field to every request would make the one thing this
/// slice can claim - that this exact header works - untrue.
public enum APIRequestHeader {
    /// Copied from the reference (`client.py:105`) and seen accepted in §3.6.
    /// Configurable rather than a literal at a call site because it is Google's
    /// to invalidate, and a rejection should be one edit rather than a search.
    public static let defaultClientVersion: Int64 = 2_440_378_181_258

    public static func make(clientVersion: Int64 = defaultClientVersion) -> RequestHeader {
        var header = RequestHeader()
        header.clientType = .web
        header.clientVersion = clientVersion
        return header
    }
}
