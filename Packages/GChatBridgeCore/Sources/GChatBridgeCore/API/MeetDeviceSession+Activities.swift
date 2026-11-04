import Foundation

public extension MeetDeviceSession {
    func performActivity(_ request: MeetActivityWire.Request) async throws -> Data {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        try request.validateScope(space.name)
        let response = try await send(request.method, body: request.body)
        return try MeetProto.decode(response.body)
    }

    func activityCollections() async throws -> MeetActivityCollections.Snapshot {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body:
            MeetActivityCollections.sync(space: space.name)
        )
        return try MeetActivityCollections.decode(response.body, space: space.name)
    }

    func activityPolicyDenials() async throws -> Set<String> {
        try begin()
        defer { busy = false }
        guard !closed, mediaConnected, device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        let user = try await send("MeetingUserService/GetUser", body: MeetProto.string(1, "users/me"))
        let data = try MeetProto.decode(user.body)
        var denied: Set<String> = []
        if MeetActivityCollections.number(48, data) == 2 {
            denied.insert("transcription")
        }
        let notes = try await send(
            "MeetingUserService/GetSmartNotesEligibilities",
            body: MeetProto.string(1, "users/me")
        )
        let eligibility = try MeetProto.decode(notes.body)
        if MeetActivityCollections.number(1, eligibility) != 2 {
            denied.insert("notes")
        }
        return denied
    }

    var activitySpace: String {
        space.name
    }
}
