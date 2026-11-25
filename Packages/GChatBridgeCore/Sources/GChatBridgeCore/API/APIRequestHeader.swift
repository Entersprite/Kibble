import Foundation

/// The `RequestHeader` every `/api/` request carries.
///
/// `findings.md` §3.6 hand-encoded `client_type: WEB` and
/// `client_version: 2440378181258` and had them accepted, which is what
/// confirmed the hand-written proto's field numbers where they were exercised.
/// Ordinary calls retain that minimal header. Feature-specific writes declare
/// the newer capabilities they implement.
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

    static func make(referenceType: Int32?) -> RequestHeader {
        var header = make()
        // The provider can accept an undeclared forward as a quoted reply.
        if referenceType == 2 {
            header.clientFeatureCapabilities.forwardedMessageLevel = .fullySupported
        }
        return header
    }

    /// The native policy writer advertises these implemented features at level2.
    /// Feature negotiation is separate from the caller's per-space edit grants.
    public static func makeForSpaceSettings() -> RequestHeader {
        var header = make()
        var features = ClientFeatureCapabilities()
        features.targetAudienceLevel = .fullySupported
        features.requestToJoinLevel = .fullySupported
        features.supportManagerRoleLevel = .fullySupported
        features.supportViewMembersPermissionLevel = .fullySupported
        features.supportJoinDiscoverPermissionLevel = .fullySupported
        header.clientFeatureCapabilities = features
        return header
    }
}
