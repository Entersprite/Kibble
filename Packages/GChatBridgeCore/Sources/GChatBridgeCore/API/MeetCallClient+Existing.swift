import Foundation

public extension MeetCallClient {
    /// Creates a traditional meeting space without joining it or inviting anyone.
    func createMeetingLink() async throws -> URL {
        let request = try configuration.request(
            method: "MeetingSpaceService/CreateMeetingSpace",
            body: MeetProto.number(8, 1)
        )
        let response = try await send(request)
        let space = try MeetCallWire.resolvedSpace(from: response.body)
        guard let link = try? MeetJoinLink(space.url), link.url == space.url else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return link.url
    }

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

    /// Display metadata for the resolved call. The agenda can be absent even
    /// when the call admits a device.
    func fetchMeetingAgendaTitle(_ call: MeetResolvedCall) async throws -> String? {
        var request = configuration.request(
            method: MeetAgendaWire.method, body: Data(), token: call.token
        )
        request.timeout = .seconds(5)
        let response = try await send(request)
        guard let event = try MeetAgendaWire.event(response.body, matching: call.space.url),
              let title = try? MeetProto.text(
                  5,
                  event
              ), title.utf8.count <= 1024 else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
