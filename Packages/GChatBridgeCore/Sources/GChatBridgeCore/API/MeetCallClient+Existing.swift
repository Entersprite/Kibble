import Foundation

public extension MeetCallClient {
    func resolveConversation(groupID: String) async throws -> MeetResolvedCall {
        let request = try configuration.request(
            method: "MeetingSpaceService/ResolveForHangoutsChat",
            body: MeetCallWire.resolveConversation(groupID: groupID)
        )
        let response = try await send(request)
        let space = try MeetCallWire.resolvedSpace(from: response.body)
        guard let token = response.headers["x-goog-meeting-token"], !token.isEmpty else {
            throw MeetCallClientError.missingMeetingToken
        }
        return MeetResolvedCall(space: space, token: token)
    }

    /// Resolve the exact currently offered reference, without an invitation,
    /// device creation or fallback to ResolveForHangoutsChat. Admission remains
    /// the provider's decision when the native device subsequently joins.
    func resolveExisting(code: String) async throws -> MeetResolvedCall {
        var request = try configuration.request(
            method: "MeetingSpaceService/ResolveMeetingSpace", body: MeetCallWire.resolveOffered(code: code)
        )
        request.headers = try HTTPHeaders(fields: request.headers.fields + [
            .init(name: "X-Goog-Meeting-Identifier", value: MeetCallWire.offeredIdentifier(code: code))
        ])
        let response = try await send(request)
        let space = try MeetCallWire.resolvedSpace(from: response.body)
        guard let token = response.headers["x-goog-meeting-token"], !token.isEmpty else {
            throw MeetCallClientError.missingMeetingToken
        }
        return MeetResolvedCall(space: space, token: token)
    }
}
